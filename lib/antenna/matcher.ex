defmodule Antenna.Matcher do
  @moduledoc """
  The behaviour defining matchers in the `Antenna` pub-sub model.

  While the matcher might be a simple function, or a process identifier,
    using this behaviour would have your testing process simplified.
  """

  @typedoc "The module implementing `handle_match/2` callback"
  @type t :: module()

  @doc "The funcion to be called back upon match"
  @callback handle_match(channel :: Antenna.channel(), event :: Antenna.event()) :: term()

  use GenServer

  @enforce_keys [:id, :match, :matcher, :handlers]
  defstruct [:id, :match, :matcher, :handlers, :channels, :once?, :caller]

  @doc false
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)

    opts =
      opts
      |> Keyword.put_new(:once?, false)
      |> Keyword.update(:channels, MapSet.new(), &MapSet.new/1)
      |> Keyword.update(:handlers, MapSet.new(), &MapSet.new/1)

    GenServer.start_link(__MODULE__, struct!(__MODULE__, opts), name: name)
  end

  @doc false
  @spec handle_event(pid(), GenServer.from() | nil, Antenna.channel(), Antenna.event()) ::
          :ok
          | {:no_match, Antenna.channel()}
          | {:match, %{match: term(), results: [term()], pid: pid(), channel: Antenna.channel()}}
  def handle_event(me, nil, channel, event),
    do: GenServer.cast(me, {:handle_event, channel, event})

  def handle_event(me, {_from, timeout, true}, channel, event) do
    GenServer.call(me, {:handle_event, channel, event}, timeout)
  end

  def handle_event(me, {_from, timeout, false}, channel, event) do
    try do
      GenServer.call(me, {:handle_event, channel, event}, timeout)
    catch
      :exit, timeout_error ->
        {:error, timeout_error}
    end
  end

  @impl GenServer
  @doc false
  def init(%__MODULE__{} = state), do: {:ok, state, {:continue, :fixup}}

  @impl GenServer
  @doc false
  def handle_continue(:fixup, %__MODULE__{} = state) do
    state = Antenna.Guard.fix(state, self())
    with pid when is_pid(pid) <- state.caller, do: send(pid, {:antenna_matcher, self()})
    {:noreply, state}
  end

  @impl GenServer
  @doc false
  def handle_cast({:handle_event, channel, event}, state) do
    if state.matcher.(event) do
      Enum.each(state.handlers, &do_handle(&1, channel, event))
      if state.once?, do: DistributedSupervisor.terminate_child(Antenna.matchers(state.id), self())
    end

    {:noreply, state}
  end

  def handle_cast({:add_handler, handler}, state),
    do: {:noreply, %__MODULE__{state | handlers: MapSet.put(state.handlers, handler)}}

  def handle_cast({:remove_handler, handler}, state),
    do: {:noreply, %__MODULE__{state | handlers: MapSet.delete(state.handlers, handler)}}

  def handle_cast(:remove_all_handlers, state),
    do: {:noreply, %__MODULE__{state | handlers: MapSet.new([])}}

  @impl GenServer
  @doc false
  def handle_call({:handle_event, channel, event}, _from, state) do
    if state.matcher.(event) do
      results = Enum.map(state.handlers, &do_handle(&1, channel, event))
      if state.once?, do: DistributedSupervisor.terminate_child(Antenna.matchers(state.id), self())
      {:reply, {:match, %{match: state.match, pid: self(), channel: channel, results: results}}, state}
    else
      {:reply, {:no_match, channel}, state}
    end
  end

  defp do_handle(process, channel, event) when is_pid(process), do: send(process, {:antenna_event, channel, event})

  defp do_handle(handler, _channel, event) when is_function(handler, 1) do
    handler.(event)
  rescue
    e ->
      require Logger
      Logger.error("[📡] Anonymous handler function failed to handle event #{inspect(event)}: #{Exception.message(e)}")

      {:error, handler, e}
  end

  defp do_handle(handler, channel, event) when is_function(handler, 2) do
    handler.(channel, event)
  rescue
    e ->
      require Logger
      Logger.error("[📡] Anonymous handler function failed to handle event #{inspect(event)}: #{Exception.message(e)}")

      {:error, handler, e}
  end

  defp do_handle(matcher, channel, event) when is_atom(matcher) do
    matcher.handle_match(channel, event)
  rescue
    e ->
      require Logger
      Logger.error("[📡] Matcher #{inspect(matcher)} failed to handle event #{inspect(event)}: #{Exception.message(e)}")

      # raise Antenna.MatcherError,
      #   message: "Matcher #{inspect(matcher)} failed to handle event #{inspect(event)}: #{e.message}"

      {:error, matcher, e}
  end
end
