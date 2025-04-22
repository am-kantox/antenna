defmodule Antenna.Matcher do
  @moduledoc """
  The behaviour defining matchers in the `Antenna` pub-sub model.

  While the matcher might be a simple function, or a process identifier,
    using this behaviour would have your testing process simplified.
  """

  @typedoc "The module implementing `handle_match/2` callback"
  @type t :: module()

  @doc "The funcion to be called back upon match"
  @callback handle_match(Antenna.channel(), Antenna.event()) :: term()

  use GenServer

  @enforce_keys [:id, :match, :matcher, :handlers]
  defstruct [:id, :match, :matcher, :handlers, :channels, :once?]

  @doc false
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    opts = opts |> Keyword.put_new(:once?, false) |> Keyword.update(:channels, MapSet.new(), &MapSet.new/1)

    GenServer.start_link(__MODULE__, struct!(__MODULE__, opts), name: name)
  end

  @doc false
  @spec handle_event(pid(), GenServer.from() | nil, Antenna.channel(), Antenna.event()) ::
          :ok
          | {:no_match, Antenna.channel()}
          | {:match, %{match: term(), results: [term()], pid: pid(), channel: Antenna.channel()}}
  def handle_event(me, nil, channel, event),
    do: GenServer.cast(me, {:handle_event, channel, event})

  def handle_event(me, _from, channel, event),
    do: GenServer.call(me, {:handle_event, channel, event})

  @impl GenServer
  @doc false
  def init(%__MODULE__{} = state), do: {:ok, state, {:continue, :channels}}

  @impl GenServer
  @doc false
  def handle_continue(:channels, %__MODULE__{channels: channels} = state) do
    state.id |> Antenna.subscribe(MapSet.to_list(channels), self())
    state.id |> Antenna.Guard.fix(state.match, self())

    {:noreply, state}
  end

  @impl GenServer
  @doc false
  def handle_cast({:handle_event, channel, event}, state) do
    if state.matcher.(event) do
      Enum.each(state.handlers, fn
        handler when is_function(handler, 1) -> handler.(event)
        handler when is_function(handler, 2) -> handler.(channel, event)
        process -> send(process, {:antenna_event, channel, event})
      end)

      if state.once?, do: DistributedSupervisor.terminate_child(Antenna.matchers(state.id), self())
    end

    {:noreply, state}
  end

  def handle_cast({:add_handler, handler}, state),
    do: {:noreply, %__MODULE__{state | handlers: [handler | state.handlers]}}

  def handle_cast({:remove_handler, handler}, state),
    do: {:noreply, %__MODULE__{state | handlers: Enum.reject(state.handlers, &(&1 == handler))}}

  @impl GenServer
  @doc false
  def handle_call({:handle_event, channel, event}, _from, state) do
    if state.matcher.(event) do
      results =
        Enum.map(state.handlers, fn
          handler when is_function(handler, 1) -> handler.(event)
          handler when is_function(handler, 2) -> handler.(channel, event)
          process -> send(process, {:antenna_event, channel, event})
        end)

      if state.once?, do: DistributedSupervisor.terminate_child(Antenna.matchers(state.id), self())

      {:reply, {:match, %{match: state.match, pid: self(), channel: channel, results: results}}, state}
    else
      {:reply, {:no_match, channel}, state}
    end
  end
end
