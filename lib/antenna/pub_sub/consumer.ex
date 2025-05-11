defmodule Antenna.PubSub.Consumer do
  @moduledoc false

  _moduledoc = """
  A GenStage consumer that processes events from the Broadcaster and distributes them to matchers.

  The Consumer is responsible for:
  - Subscribing to the Broadcaster
  - Filtering events for the current node
  - Distributing events to appropriate matchers
  - Collecting and forwarding responses for synchronous events

  ## Node-specific Processing

  The Consumer implements node-specific event filtering:
  - Only processes events meant for the current node
  - Uses `DistributedSupervisor.mine?/2` for filtering
  - Prevents duplicate event processing in distributed setups

  ## Channel Distribution

  Events are distributed based on channel subscriptions:
  - Supports wildcard channel `:*` for broadcasting to all channels
  - Maintains separate channel groups using `:pg`
  - Efficiently delivers events only to interested matchers

  ## Configuration

  Consumer behavior can be configured through the `:broadcaster_opts`:

  ```elixir
  config :antenna,
    broadcaster_opts: [
      max_demand: 1000,  # Maximum number of events to request
      min_demand: 500    # Threshold for requesting more events
    ]
  ```

  The above configuration helps tune the event flow based on your system's needs:
  - Higher values improve throughput but use more memory
  - Lower values reduce memory usage but may impact throughput
  - Default values are suitable for most use cases
  """

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
