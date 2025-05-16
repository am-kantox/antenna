defmodule Antenna.PubSub.Broadcaster do
  @moduledoc false

  _moduledoc = """
  A GenStage producer that handles event broadcasting in the Antenna system.

  The Broadcaster is responsible for:
  - Receiving events from clients
  - Managing event queues
  - Implementing back-pressure
  - Distributing events to consumers

  ## Event Types

  The Broadcaster supports two types of event delivery:

  1. **Synchronous** (`sync_notify/3`)
     - Waits for event delivery before returning
     - Collects responses from handlers
     - Useful when you need confirmation of event processing

  2. **Asynchronous** (`async_notify/2`)
     - Returns immediately after queueing the event
     - No response collection
     - Better performance for high-throughput scenarios

  ## Back-pressure

  The Broadcaster implements GenStage's demand-driven flow control:
  - Events are queued when demand is low
  - Events are dispatched based on consumer demand
  - Prevents system overload during high event volume

  ## Examples

  ```elixir
  # Synchronous notification with response collection
  responses = Broadcaster.sync_notify(MyApp.Antenna, {:user_event, user_data}, 5000)

  # Asynchronous notification
  :ok = Broadcaster.async_notify(MyApp.Antenna, {:background_task, task_data})
  ```
  """

  use GenStage

  @doc """
  Starts the broadcaster.
  """
  def start_link(opts \\ []) do
    {id, opts} = Antenna.id_opts(opts)
    GenStage.start_link(__MODULE__, opts, name: id)
  end

  @doc """
  Sends an event and returns only after the event is dispatched.
  """
  def sync_notify(id, event, timeout, extra_timeout, raise?) do
    DistributedSupervisor.call(
      id,
      Antenna.PubSub.broadcaster_name(id),
      {:notify, event, timeout, raise?},
      timeout + extra_timeout
    )
  end

  @doc """
  Sends an event and returns immediately.
  """
  def async_notify(id, event) do
    DistributedSupervisor.cast(
      id,
      Antenna.PubSub.broadcaster_name(id),
      {:notify, event}
    )
  end

  ## Callbacks

  def init(_opts), do: {:producer, {:queue.new(), 0}, dispatcher: GenStage.BroadcastDispatcher}

  def handle_call({:notify, event, timeout, raise?}, from, {queue, demand}),
    do: dispatch_events(:queue.in({{from, timeout, raise?}, event}, queue), demand, [])

  def handle_cast({:notify, event}, {queue, demand}),
    do: dispatch_events(:queue.in({nil, event}, queue), demand, [])

  def handle_demand(incoming_demand, {queue, demand}),
    do: dispatch_events(queue, incoming_demand + demand, [])

  defp dispatch_events(queue, demand, events) when demand <= 0,
    do: {:noreply, Enum.reverse(events), {queue, demand}}

  defp dispatch_events(queue, demand, events) do
    case :queue.out(queue) do
      {{:value, {from, event}}, queue} ->
        dispatch_events(queue, demand - 1, [{from, event} | events])

      _ ->
        {:noreply, Enum.reverse(events), {queue, demand}}
    end
  end
end
