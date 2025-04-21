defmodule Antenna.Matcher do
  @moduledoc """
  The behaviour defining matchers in the `Antenna` pub-sub model.
  """

  @callback handle_match(term()) :: any()

  use GenServer

  @enforce_keys [:id, :match, :matcher, :handlers]
  defstruct [:id, :match, :matcher, :handlers, :channels, :once?]

  @doc false
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    opts = opts |> Keyword.put_new(:once?, false) |> Keyword.update(:channels, MapSet.new(), &MapSet.new/1)

    GenServer.start_link(__MODULE__, struct!(__MODULE__, opts), name: name)
  end

  def handle_event(me, channel, event), do: GenServer.cast(me, {:handle_event, channel, event})

  @impl GenServer
  def init(%__MODULE__{} = state), do: {:ok, state, {:continue, :channels}}

  @impl GenServer
  def handle_continue(:channels, %__MODULE__{channels: channels} = state) do
    state.id |> Antenna.subscribe(MapSet.to_list(channels), self())
    state.id |> Antenna.Guard.fix(state.match, self())

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:handle_event, channel, event}, state) do
    if state.matcher.(event) do
      Enum.each(state.handlers, fn
        handler when is_function(handler, 1) -> handler.(event)
        handler when is_function(handler, 2) -> handler.(channel, event)
        process -> send(process, {:antenna_event, channel, event})
      end)
    end

    if state.once?, do: DistributedSupervisor.terminate_child(Antenna.matchers(state.id), self())

    {:noreply, state}
  end

  def handle_cast({:add_handler, handler}, state),
    do: {:noreply, %__MODULE__{state | handlers: [handler | state.handlers]}}

  def handle_cast({:remove_handler, handler}, state),
    do: {:noreply, %__MODULE__{state | handlers: Enum.reject(state.handlers, &(&1 == handler))}}
end
