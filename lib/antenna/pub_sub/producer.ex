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
  def sync_notify(name \\ Antenna.Matchers, event, timeout \\ 5000) do
    DistributedSupervisor.call(
      name,
      Antenna.PubSub.broadcaster_name(name),
      {:notify, event},
      timeout
    )
  end

  ## Callbacks

  def init(_opts), do: {:producer, {:queue.new(), 0}, dispatcher: GenStage.BroadcastDispatcher}

  def handle_call({:notify, event}, from, {queue, demand}),
    do: dispatch_events(:queue.in({from, event}, queue), demand, [])

  def handle_demand(incoming_demand, {queue, demand}),
    do: dispatch_events(queue, incoming_demand + demand, [])

  defp dispatch_events(queue, demand, events) do
    with d when d > 0 <- demand,
         {{:value, {from, event}}, queue} <- :queue.out(queue) do
      GenStage.reply(from, :ok)
      dispatch_events(queue, demand - 1, [event | events])
    else
      _ -> {:noreply, Enum.reverse(events), {queue, demand}}
    end
  end
end
