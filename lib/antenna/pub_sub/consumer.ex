defmodule Antenna.PubSub.Consumer do
  @moduledoc false

  use GenStage

  require Logger

  def start_link(opts) do
    {id, opts} = Antenna.id_opts(opts) |> IO.inspect(label: "CONSUMER")
    {broadcaster_name, opts} = Keyword.pop!(opts, :broadcaster)
    GenStage.start_link(__MODULE__, {id, broadcaster_name}, opts)
  end

  # Callbacks

  @impl GenStage
  def init({id, broadcaster_name}), do: {:consumer, id, subscribe_to: [{broadcaster_name, []}]}

  @impl GenStage
  def handle_events(events, _from, id) do
    # AM might be more efficient with group_by/2
    for {channels, event} <- events,
        DistributedSupervisor.mine?(id, event),
        channel <- if(:* in channels, do: :pg.which_groups(Antenna.channels(Antenna)), else: channels),
        pid <- :pg.get_members(Antenna.channels(Antenna), channel) do
      Antenna.Matcher.handle_event(pid, channel, event)
    end

    {:noreply, [], id}
  end

  @impl GenStage
  def handle_info({:DOWN, _ref, :process, remote_pid, :noconnection}, state)
      when node(remote_pid) != node(),
      do: {:noreply, [], state}
end
