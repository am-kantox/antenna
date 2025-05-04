defmodule Antenna.PubSub.Consumer do
  @moduledoc false

  use GenStage

  @broadcaster_opts Application.compile_env(:antenna, :broadcaster_opts, [])

  require Logger

  def start_link(opts) do
    {id, opts} = Antenna.id_opts(opts)
    {broadcaster_name, opts} = Keyword.pop!(opts, :broadcaster)

    GenStage.start_link(__MODULE__, {id, broadcaster_name}, opts)
  end

  # Callbacks

  @impl GenStage
  def init({id, broadcaster_name}),
    do: {:consumer, id, subscribe_to: [{broadcaster_name, @broadcaster_opts}]}

  @impl GenStage
  def handle_events(events, _from, id) do
    results =
      for {from, {channels, event}} <- events,
          DistributedSupervisor.mine?(Antenna.delivery(id), event),
          channel <- if(:* in channels, do: :pg.which_groups(Antenna.channels(id)), else: channels),
          pid <- :pg.get_members(Antenna.channels(id), channel),
          reduce: %{} do
        acc ->
          result = Antenna.Matcher.handle_event(pid, from, channel, event)
          Map.update(acc, from, [result], &[result | &1])
      end

    Enum.each(results, fn
      {nil, _} -> :ok
      {from, results} -> GenStage.reply(from, results)
    end)

    {:noreply, [], id}
  end

  @impl GenStage
  def handle_info({:DOWN, _ref, :process, remote_pid, :noconnection}, state)
      when node(remote_pid) != node(),
      do: {:noreply, [], state}
end
