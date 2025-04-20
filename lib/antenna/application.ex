defmodule Antenna.Application do
  @moduledoc false

  use Elixir.Application

  @impl Elixir.Application
  def start(_type, _args) do
    children = [
      %{id: :pg, start: {__MODULE__, :start_pg, []}},
      {Antenna.PubSub, id: Antenna.delivery()},
      {DistributedSupervisor, name: Antenna.matchers(), monitor_nodes: true}
    ]

    opts = [strategy: :one_for_one]

    Supervisor.start_link(children, opts)
  end

  @impl Application
  def start_phase(:antenna_setup, _start_type, []), do: :ok

  @doc false
  @spec start_pg(module()) :: {:ok, pid()} | :ignore
  def start_pg(scope \\ Antenna.tags()) do
    with {:error, {:already_started, _pid}} <- :pg.start_link(scope), do: :ignore
  end
end
