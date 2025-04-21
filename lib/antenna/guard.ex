defmodule Antenna.Guard do
  @moduledoc false
  use GenServer

  defstruct [:id, :reference, :groups, :subscriptions]

  def start_link(id: id) do
    GenServer.start_link(__MODULE__, id, name: Antenna.guard(id))
  end

  def add(id, channel, pid), do: id |> Antenna.guard() |> GenServer.cast({:add, channel, pid})
  def remove(id, channel, pid), do: id |> Antenna.guard() |> GenServer.cast({:remove, channel, pid})
  def fix(id, name, pid \\ nil), do: id |> Antenna.guard() |> GenServer.cast({:fix, name, pid})
  def all(id, name), do: id |> Antenna.guard() |> GenServer.call({:all, name})

  # Callbacks

  @impl GenServer
  def init(id) do
    {reference, %{} = groups} = id |> Antenna.channels() |> :pg.monitor_scope()
    {:ok, struct!(__MODULE__, id: id, reference: reference, groups: groups, subscriptions: from_groups(groups))}
  end

  @impl GenServer
  def handle_cast({:add, channel, pid}, state) do
    subscriptions =
      case state.id |> Antenna.matchers() |> DistributedSupervisor.whois(pid) do
        nil -> state.subscriptions
        name -> Map.update(state.subscriptions, name, [channel], &[channel | &1])
      end

    {:noreply, %__MODULE__{state | subscriptions: subscriptions}}
  end

  def handle_cast({:remove, channel, pid}, state) do
    subscriptions =
      case state.id |> Antenna.matchers() |> DistributedSupervisor.whois(pid) do
        nil ->
          state.subscriptions

        name ->
          Map.update(state.subscriptions, name, [channel], fn channels -> Enum.reject(channels, &(channel == &1)) end)
      end

    {:noreply, %__MODULE__{state | subscriptions: subscriptions}}
  end

  def handle_cast({:fix, name, pid}, state) do
    pid = with nil <- pid, do: DistributedSupervisor.whereis(state.id, name)
    Antenna.subscribe(state.id, Map.get(state.subscriptions, name, []), pid)

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:all, name}, _from, state), do: {:reply, Map.get(state.subscriptions, name, []), state}

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

  defp from_groups(%{} = chan_to_pids) do
    Enum.reduce(chan_to_pids, %{}, fn {chan, pids}, acc ->
      Enum.reduce(pids, acc, fn pid, acc ->
        Map.update(acc, pid, [chan], &[chan | &1])
      end)
    end)
  end
end
