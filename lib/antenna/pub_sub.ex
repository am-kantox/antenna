defmodule Antenna.PubSub do
  @moduledoc false

  alias Antenna.PubSub.{Broadcaster, Consumer}

  def start_link(opts \\ []) do
    {id, _opts} = Antenna.id_opts(opts)
    id = Antenna.delivery(id)

    with {:ok, pid} <- DistributedSupervisor.start_link(name: id, monitor_nodes: true),
         {:ok, _broadcaster_pid, name} <-
           DistributedSupervisor.start_child(id, {Broadcaster, name: broadcaster_name(id)}),
         broadcaster_name <- DistributedSupervisor.via_name(id, name),
         {:ok, _consumer_pid, ref} when is_reference(ref) <-
           DistributedSupervisor.start_child(id, {Consumer, id: id, broadcaster: broadcaster_name}),
         do: {:ok, pid}
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
end
