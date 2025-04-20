defmodule Antenna.Matcher do
  @moduledoc """
  The behaviour defining matchers in the `Antenna` pub-sub model.
  """

  @callback handle_match(term()) :: any()

  use GenServer

  defstruct matcher: nil, handlers: [], tags: MapSet.new()

  @doc false
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, struct!(__MODULE__, opts), name: name)
  end

  def handle_event(me, event), do: GenServer.cast(me, {:handle_event, event})

  @impl GenServer
  def init(%__MODULE__{} = state), do: {:ok, state, {:continue, :tags}}

  @impl GenServer
  def handle_cast({:handle_event, event}, state) do
    if state.matcher.(event) do
      Enum.each(state.handlers, fn
        handler when is_function(handler) -> handler.(event)
        process -> send(process, {:antenna_event, self(), event})
      end)
    end

    {:noreply, state}
  end

  def handle_cast({:add_handler, handler}, state),
    do: {:noreply, %__MODULE__{state | handlers: [handler | state.handlers]}}

  def handle_cast({:remove_handler, handler}, state),
    do: {:noreply, %__MODULE__{state | handlers: Enum.reject(state.handlers, &(&1 == handler))}}

  @impl GenServer
  def handle_continue(:tags, %__MODULE__{tags: tags} = state) do
    Antenna.attach(tags, self())
    {:noreply, %__MODULE__{state | tags: MapSet.new(tags)}}
  end
end
