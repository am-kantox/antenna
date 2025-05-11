defmodule Antenna.PubSub do
  @moduledoc """
  The Pub/Sub system that powers Antenna's event distribution.

  This module implements a distributed publish/subscribe system using GenStage,
  allowing for efficient event broadcasting across nodes with back-pressure support.

  ## Architecture

  The PubSub system consists of three main components:

  1. **Broadcaster** (`Antenna.PubSub.Broadcaster`)
     - Acts as a GenStage producer
     - Handles event broadcasting
     - Manages event queuing and demand
     - Supports both synchronous and asynchronous event delivery

  2. **Consumer** (`Antenna.PubSub.Consumer`)
     - Acts as a GenStage consumer
     - Receives events from the broadcaster
     - Distributes events to appropriate matchers
     - Handles node-specific event filtering

  3. **Supervisor** (`Antenna.PubSub`)
     - Manages the lifecycle of broadcasters and consumers
     - Handles distributed supervision
     - Ensures proper startup and shutdown of components

  ## Event Flow

  1. Events are sent to the Broadcaster (sync or async)
  2. Broadcaster queues events and handles back-pressure
  3. Consumer receives events based on demand
  4. Consumer filters events for the current node
  5. Events are distributed to matching handlers

  ## Configuration

  The PubSub system can be configured in your config.exs:

  ```elixir
  config :antenna,
    broadcaster_opts: [
      # Options passed to GenStage.sync_subscribe/3
      max_demand: 1000,
      min_demand: 500
    ]
  ```
  """

  alias Antenna.PubSub.{Broadcaster, Consumer}

  def start_link(opts \\ []) do
    {id, _opts} = Antenna.id_opts(opts)
    delivery_id = Antenna.delivery(id)

    with {{:ok, _pid}, return} <- start_ds(name: delivery_id, monitor_nodes: true),
         {:ok, _broadcaster_pid, name} <- start_dbc(delivery_id),
         broadcaster_name <- DistributedSupervisor.via_name(delivery_id, name),
         {:ok, _consumer_pid, ref} when is_reference(ref) <-
           DistributedSupervisor.start_child(delivery_id, {Consumer, id: id, broadcaster: broadcaster_name}) do
      return
    else
      error ->
        require Logger
        Logger.alert("PubSub failed to start at #{node()}: " <> inspect(error))
        :ignore
    end
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5000
    }
  end

  def broadcaster_name(id) when is_atom(id),
    do: Module.concat(id, :Broadcaster)

  def broadcaster(id) when is_atom(id),
    do: DistributedSupervisor.whereis(id, broadcaster_name(id))

  def start_ds(opts) do
    case DistributedSupervisor.start_link(opts) do
      {:error, {:already_started, pid}} -> {{:ok, pid}, :ignore}
      {:ok, pid} -> {{:ok, pid}, {:ok, pid}}
      other -> other
    end
  end

  def start_dbc(id) do
    broadcaster_name = broadcaster_name(id)

    with {:error, {:already_started, pid}} <-
           DistributedSupervisor.start_child(id, {Broadcaster, name: broadcaster_name}),
         do: {:ok, pid, broadcaster_name}
  end
end
