defmodule Antenna.PubSub.Broadcaster do
  @moduledoc false

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
  def sync_notify(id, event, timeout \\ 5000) do
    DistributedSupervisor.call(
      id,
      Antenna.PubSub.broadcaster_name(id),
      {:notify, event},
      timeout
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

  def handle_call({:notify, event}, from, {queue, demand}),
    do: dispatch_events(:queue.in({from, event}, queue), demand, [])

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
