defmodule Antenna.PubSub.Consumer do
  @moduledoc false

  use GenStage

  require Logger

  def start_link(opts) do
    {id, opts} = Antenna.id_opts(opts)
    {broadcaster_name, opts} = Keyword.pop!(opts, :broadcaster)
    GenStage.start_link(__MODULE__, {id, broadcaster_name}, opts)
  end

  defmacro unquote_match(match, event) do
    # {:case, [],
    #  [
    #    quote(do: unquote(event)),
    #    [
    #      do: [
    #        {:->, [], [[quote(do: unquote(match))], true]},
    #        {:->, [], [[{:_, [], Elixir}], false]}
    #      ]
    #    ]
    #  ]}
    {:match?, [context: Elixir, imports: [{2, Kernel}]],
     [
       quote(do: unquote(Macro.escape(match, unquote: true))),
       quote(do: unquote(Macro.escape(event)))
     ]}
  end

  # Callbacks

  @impl GenStage
  def init({id, broadcaster_name}), do: {:consumer, id, subscribe_to: [{broadcaster_name, []}]}

  @impl GenStage
  def handle_events(events, _from, id) do
    # AM might be more efficient with group_by/2
    for {tags, event} <- events,
        DistributedSupervisor.mine?(id, event),
        tag <- tags,
        pid <- :pg.get_members(Antenna.tags(), tag) do
      Antenna.Matcher.handle_event(pid, event)
    end

    {:noreply, [], id}
  end

  @impl GenStage
  def handle_info({:DOWN, _ref, :process, remote_pid, :noconnection}, state)
      when node(remote_pid) != node(),
      do: {:noreply, [], state}
end
