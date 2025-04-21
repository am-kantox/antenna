defmodule Antenna.Guard do
  @moduledoc false
  use GenServer

  defstruct [:id, :reference, :groups]

  def start_link(id: id) do
    GenServer.start_link(__MODULE__, id, name: Antenna.guard(id))
  end

  # Callbacks

  @impl GenServer
  def init(id) do
    {reference, %{} = groups} = id |> Antenna.channels() |> :pg.monitor_scope()
    {:ok, struct!(__MODULE__, id: id, reference: reference, groups: groups)}
  end

  @impl GenServer
  def handle_info({ref, :join, group, pids}, %__MODULE__{reference: ref} = state) do
    pids = MapSet.new(pids)
    groups = Map.update(state.groups, group, pids, &MapSet.union(&1, pids))
    {:noreply, %__MODULE__{state | groups: groups}}
  end

  def handle_info({ref, :leave, group, pids}, %__MODULE__{reference: ref} = state) do
    pids = MapSet.new(pids)
    groups = Map.update(state.groups, group, pids, &MapSet.difference(&1, pids))
    {:noreply, %__MODULE__{state | groups: groups}}
  end
end
