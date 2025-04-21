defmodule Antenna.Application do
  @moduledoc false

  use Elixir.Application

  @impl Elixir.Application
  def start(_type, args) do
    id = with true <- Keyword.keyword?(args), {:ok, id} <- Keyword.fetch(args, :id), do: id, else: (_ -> Antenna.id())

    children = [
      %{id: :pg, start: {__MODULE__, :start_pg, [Antenna.channels(id)]}},
      {Antenna.Guard, id: id},
      {Antenna.PubSub, id: id},
      {DistributedSupervisor, name: Antenna.matchers(id), monitor_nodes: true}
    ]

    opts = [strategy: :one_for_one]

    Supervisor.start_link(children, opts)
  end

  @impl Application
  def start_phase(:antenna_setup, _start_type, []), do: :ok

  @doc false
  @spec start_pg(module()) :: {:ok, pid()} | :ignore
  def start_pg(scope) do
    with {:error, {:already_started, _pid}} <- :pg.start_link(scope), do: :ignore
  end
end
