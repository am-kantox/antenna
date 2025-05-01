defmodule Antenna.Guard do
  @moduledoc false
  use GenServer

  defstruct [:id, :reference, :groups, :channels, :handlers]

  def start_link(id: id) do
    GenServer.start_link(__MODULE__, id, name: Antenna.guard(id))
  end

  def add_channel(id, channel, pid), do: id |> Antenna.guard() |> GenServer.cast({:add_channel, channel, pid})
  def remove_channel(id, channel, pid), do: id |> Antenna.guard() |> GenServer.cast({:remove_channel, channel, pid})
  def add_handler(id, handler, pid), do: id |> Antenna.guard() |> GenServer.cast({:add_handler, handler, pid})
  def remove_handler(id, handler, pid), do: id |> Antenna.guard() |> GenServer.cast({:remove_handler, handler, pid})

  def fix(id, name, pid \\ nil), do: id |> Antenna.guard() |> GenServer.cast({:fix, name, pid})
  def all(id, name), do: id |> Antenna.guard() |> GenServer.call({:all, name})

  # Callbacks

  @impl GenServer
  def init(id) do
    {reference, %{} = groups} = id |> Antenna.channels() |> :pg.monitor_scope()

    {:ok,
     struct!(__MODULE__,
       id: id,
       reference: reference,
       groups: groups,
       channels: from_groups(id, groups),
       handlers: %{}
     )}
  end

  @impl GenServer
  def handle_cast({:add_channel, channel, pid}, state) do
    channels =
      case pid_to_name(state.id, pid) do
        nil -> state.channels
        name -> Map.update(state.channels, name, [channel], &[channel | &1])
      end

    {:noreply, %__MODULE__{state | channels: channels}}
  end

  def handle_cast({:remove_channel, channel, pid}, state) do
    channels =
      case pid_to_name(state.id, pid) do
        nil ->
          state.channels

        name ->
          Map.update(state.channels, name, [channel], fn channels -> Enum.reject(channels, &(channel == &1)) end)
      end

    {:noreply, %__MODULE__{state | channels: channels}}
  end

  @impl GenServer
  def handle_cast({:add_handler, handler, pid}, state) do
    handlers =
      case pid_to_name(state.id, pid) do
        nil -> state.handlers
        name -> Map.update(state.handlers, name, [handler], &[handler | &1])
      end

    {:noreply, %__MODULE__{state | handlers: handlers}}
  end

  def handle_cast({:remove_handler, handler, pid}, state) do
    handlers =
      case pid_to_name(state.id, pid) do
        nil ->
          state.handlers

        name ->
          Map.update(state.handlers, name, [handler], fn handlers -> Enum.reject(handlers, &(handler == &1)) end)
      end

    {:noreply, %__MODULE__{state | handlers: handlers}}
  end

  def handle_cast({:fix, name, nil}, state),
    do: handle_cast({:fix, name, name_to_pid(state.id, name)}, state)

  def handle_cast({:fix, name, :undefined}, state),
    do: handle_cast({:fix, name, name_to_pid(state.id, name)}, state)

  def handle_cast({:fix, name, pid}, state) do
    pid = pid && name_to_pid(state.id, name)

    Antenna.subscribe(state.id, Map.get(state.channels, name, []), pid)
    Antenna.handle(state.id, Map.get(state.handlers, name, []), pid)

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:all, name}, _from, state),
    do: {:reply, %{channels: Map.get(state.channels, name, []), handlers: Map.get(state.handlers, name, [])}, state}

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

  defp from_groups(id, %{} = chan_to_pids) do
    Enum.reduce(chan_to_pids, %{}, fn {chan, pids}, acc ->
      Enum.reduce(pids, acc, fn pid, acc ->
        Map.update(acc, pid_to_name(id, pid), [chan], &[chan | &1])
      end)
    end)
  end

  defp pid_to_name(id, pid), do: id |> Antenna.matchers() |> DistributedSupervisor.whois(pid)
  defp name_to_pid(id, name), do: id |> Antenna.matchers() |> DistributedSupervisor.whereis(name)
end
