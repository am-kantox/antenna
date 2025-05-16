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
  def remove_all_handlers(id, pid), do: id |> Antenna.guard() |> GenServer.cast({:remove_all_handlers, pid})

  def fix(state, pid \\ nil), do: state.id |> Antenna.guard() |> GenServer.call({:fix, state, pid})
  def all(id), do: id |> Antenna.guard() |> GenServer.call(:all)
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
        name -> Map.update(state.channels, name, MapSet.new([channel]), &MapSet.put(&1, channel))
      end

    {:noreply, %__MODULE__{state | channels: channels}}
  end

  def handle_cast({:remove_channel, channel, pid}, state) do
    channels =
      case pid_to_name(state.id, pid) do
        nil -> state.channels
        name -> Map.update(state.channels, name, MapSet.new(), &MapSet.delete(&1, channel))
      end

    {:noreply, %__MODULE__{state | channels: channels}}
  end

  @impl GenServer
  def handle_cast({:add_handler, handler, pid}, state) do
    handlers =
      case pid_to_name(state.id, pid) do
        nil -> state.handlers
        name -> Map.update(state.handlers, name, MapSet.new([handler]), &MapSet.put(&1, handler))
      end

    {:noreply, %__MODULE__{state | handlers: handlers}}
  end

  def handle_cast({:remove_handler, handler, pid}, state) do
    handlers =
      case pid_to_name(state.id, pid) do
        nil -> state.handlers
        name -> Map.update(state.handlers, name, MapSet.new(), &MapSet.delete(&1, handler))
      end

    {:noreply, %__MODULE__{state | handlers: handlers}}
  end

  def handle_cast({:remove_all_handlers, pid}, state) do
    handlers =
      case pid_to_name(state.id, pid) do
        nil -> state.handlers
        name -> Map.delete(state.handlers, name)
      end

    {:noreply, %__MODULE__{state | handlers: handlers}}
  end

  def handle_call({:fix, %{id: id} = match_state, unexpected}, from, %{id: id} = state)
      when unexpected in [nil, :undefined, :restarting],
      do: handle_call({:fix, match_state, name_to_pid(id, match_state.match)}, from, state)

  def handle_call({:fix, %{id: id} = match_state, pid}, _from, %{id: id} = state) when is_pid(pid) do
    name = match_state.match

    channels = state.channels |> Map.get(name, MapSet.new()) |> MapSet.union(match_state.channels)
    Antenna.subscribe(state.id, channels, pid)
    handlers = state.handlers |> Map.get(name, MapSet.new()) |> MapSet.union(match_state.handlers)
    Antenna.handle(state.id, handlers, pid)

    {:reply, %{match_state | channels: channels, handlers: handlers}, %{state | channels: channels, handlers: handlers}}
  end

  @impl GenServer
  def handle_call(:all, _from, state) do
    {:reply, Map.take(state, [:handlers, :channels]), state}
  end

  @impl GenServer
  def handle_call({:all, name}, _from, state) do
    {:reply,
     %{channels: Map.get(state.channels, name, MapSet.new()), handlers: Map.get(state.handlers, name, MapSet.new())},
     state}
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
