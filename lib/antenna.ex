defmodule Antenna do
  @moduledoc """
  `Antenna` is a mixture of `Phoenix.PubSub` and 
    [`:gen_event`](https://www.erlang.org/doc/apps/stdlib/gen_event.html)
    functionality with some batteries included.

  It implements back-pressure on top of `GenStage`, is fully conformant with
    [OTP Design Principles](https://www.erlang.org/doc/system/events). and
    is distributed out of the box.

  One can have as many isolated `Antenna`s as necessary, distinguished by `t:id()`.

  The workflow looks like shown below.

  ```
                          ┌───────────────┐                                               
                          │               │       Antenna.event(AntID, :tag1, %{foo: 42}) 
                          │  Broadcaster  │───────────────────────────────────────────────
                          │               │                                               
                          └───────────────┘                                               
                                ──/──                                                     
                          ────── /   ─────                                                
                    ──────      /         ──────                                          
              ──────           /                ─────                                     
          ────                /                      ───                                  
  ┌────────────────┐  ┌────────────────┐       ┌────────────────┐                         
  │                │  │                │       │                │                         
  │ Consumer@node1 │  │ Consumer@node1 │   …   │ Consumer@nodeN │                         
  │                │  │                │       │                │                         
  └────────────────┘  └────────────────┘       └────────────────┘                         
          ·                   ·                         ·                                 
        /   \               /   \                     /   \                               
      /       \           /       \                 /       \                             
    ·   mine?   ·       ·   mine?   ·             ·   mine?   ·                           
      \       /           \       /                 \       /                             
        \   /               \   /                     \   /                               
          ·                   ·                         ·                                 
          │                   │                         │                                 
          │                   │                         │                                 
        ─────                 │                       ─────                               
                              │                                                           
                              │                                                           
                       ┌──────────────┐                                                   
                       │              │             if (match?), do: call_handlers(event) 
                       │   matchers   │───────────────────────────────────────────────────
                       │              │                                                   
                       └──────────────┘                                                   
  ```

  ## Usage example

  The consumer of this library is supposed to declare one or more matchers, subscribing to one
    or more channels, and then call `Antenna.event/2` to propagate the event.

  ```elixir
  assert {:ok, pid1, "{:tag_1, a, _} when is_nil(a)"} =
    Antenna.match(Antenna, {:tag_1, a, _} when is_nil(a), self(), channels: [:chan_1])

  assert :ok = Antenna.event(Antenna, [:chan_1], {:tag_1, nil, 42})
  assert_receive {:antenna_event, :chan_1, {:tag_1, nil, 42}}
  ```
  """

  # Edit/view: https://cascii.app/4164d

  alias Antenna.PubSub.Broadcaster

  @typedoc "The identifier of the isolated `Antenna`"
  @type id :: module()

  @typedoc "The identifier of the channel, messages can be sent to, preferrably `atom()`"
  @type channel :: atom() | term()

  @typedoc "The event being sent to the listeners"
  @type event :: term()

  @typedoc """
  The actual handler to be associated with an event(s). It might be either a function
    or a process id, in which case the message of a following shape will be sent to it.

  ```elixir
  {:antenna_event, channel, event}
  ```
  """
  @type handler :: (event() -> :ok) | (channel(), event() -> :ok) | Antenna.Matcher.t() | pid() | GenServer.name()

  @id Application.compile_env(:antenna, :id, Antenna)

  @doc false
  def id, do: @id
  @doc false
  def delivery(id), do: Module.concat(id, Delivery)
  @doc false
  def matchers(id), do: Module.concat(id, Matchers)
  @doc false
  def channels(id), do: Module.concat(id, Channels)
  @doc false
  def guard(id), do: Module.concat(id, Guard)

  @doc false
  def id_opts(%{id: id} = opts), do: {id, Map.delete(opts, :id)}
  def id_opts(%{name: id} = opts), do: {id, Map.delete(opts, :name)}

  def id_opts(opts) do
    if Keyword.keyword?(opts),
      do: Keyword.pop_lazy(opts, :id, fn -> Keyword.get(opts, :name, __MODULE__) end),
      else: {opts, []}
  end

  @doc """
  Declares a matcher for tagged events.

  ### Example

  ```elixir
  Antenna.match(Antenna, %{tag: _, success: false}, fn channel, message ->
    Logger.warning("The processing failed for [" <> 
      inspect(channel) <> "], result: " <> inspect(message))
  end, channels: [:rabbit])
  ```
  """
  defmacro match(id \\ @id, match, handlers, opts \\ [])

  defmacro match(id, match, handlers, opts) do
    name = Macro.to_string(match)

    quote generated: true, location: :keep do
      matcher = fn
        unquote(match) -> true
        _ -> false
      end

      opts = unquote(opts)

      DistributedSupervisor.start_child(
        Antenna.matchers(unquote(id)),
        {Antenna.Matcher,
         name: unquote(name),
         id: unquote(id),
         match: unquote(name),
         matcher: matcher,
         handlers: List.wrap(unquote(handlers)),
         channels: List.wrap(Keyword.get(opts, :channels)),
         once?: Keyword.get(opts, :once?, false)}
      )
    end
  end

  @doc """
  Undeclares a matcher for tagged events previously declared with `Antenna.match/4`.

  Accepts both an original match _or_ a name returned by `Antenna.match/4`,
    which is effectively `Macro.to_string(match)`.

  ### Example

  ```elixir
  Antenna.unmatch(Antenna, %{tag: _, success: false})
  ```
  """
  defmacro unmatch(id \\ @id, match) do
    quote generated: true, location: :keep do
      with pid when is_pid(pid) <- Antenna.whereis(unquote(id), unquote(match)),
           do: DistributedSupervisor.terminate_child(Antenna.matchers(unquote(id)), pid)
    end
  end

  @doc false
  defmacro attach(id \\ @id, channels, match) do
    quote generated: true, location: :keep do
      with pid when is_pid(pid) <- Antenna.whereis(unquote(id), unquote(match)),
           do: Antenna.subscribe(unquote(id), unquote(channels), pid)
    end
  end

  @doc false
  defmacro unattach(id \\ @id, channels, match) do
    quote generated: true, location: :keep do
      with pid when is_pid(pid) <- Antenna.whereis(unquote(id), unquote(match)),
           do: Antenna.unsubscribe(unquote(id), unquote(channels), pid)
    end
  end

  @doc """
  Subscribes a matcher process specified by `pid` to a channel(s)
  """
  @spec subscribe(id :: id(), channels :: channel() | [channel()], pid()) :: :ok
  def subscribe(id \\ @id, channels, pid)

  def subscribe(_, [], _), do: :ok

  def subscribe(id, channels, pid) when is_pid(pid) do
    channels
    |> List.wrap()
    |> Enum.each(&join(id, &1, pid))
  end

  @doc """
  Unsubscribes a previously subscribed matcher process specified by `pid` from the channel(s)
  """
  @spec unsubscribe(id :: id(), channels :: channel() | [channel()], pid()) :: :ok
  def unsubscribe(id \\ @id, channels, pid)

  def unsubscribe(_, [], _), do: :ok

  def unsubscribe(id, channels, pid) when is_pid(pid) do
    channels
    |> List.wrap()
    |> Enum.each(&leave(id, &1, pid))
  end

  @doc false
  defmacro whereis(id \\ @id, match)
  defmacro whereis(id, match) when is_binary(match), do: do_whereis(id, match)
  defmacro whereis(id, match), do: do_whereis(id, Macro.to_string(match))

  defp do_whereis(id, match) do
    quote generated: true, location: :keep do
      case DistributedSupervisor.children(Antenna.matchers(unquote(id))) do
        %{unquote(match) => {pid, _spec}} when is_pid(pid) -> pid
        _ -> nil
      end
    end
  end

  @doc """
  Sends an event to all the associated matchers through channels.

  The special `:*` might be specified as channels, then the event
    will be sent to all the registered channels.
  """
  @spec event(id :: id(), channels :: channel() | [channel()], event :: event()) :: :ok
  def event(id \\ @id, channels, event),
    do: Broadcaster.sync_notify(Antenna.delivery(id), {List.wrap(channels), event})

  @doc """
  Returns a map of matches to matchers
  """
  @spec registered_matchers(id :: id()) :: %{term() => {pid(), Supervisor.child_spec()}}
  def registered_matchers(id),
    do: id |> Antenna.matchers() |> DistributedSupervisor.children()

  @spec join(id(), channel(), pid()) :: :ok | :already_joined
  defp join(id, channel, pid) do
    scope = channels(id)

    if pid in :pg.get_members(scope, channel) do
      :already_joined
    else
      :ok = Antenna.Guard.add(id, channel, pid)
      :pg.join(scope, channel, pid)
    end
  end

  @spec leave(id(), channel(), pid()) :: :ok | :not_joined
  defp leave(id, channel, pid) do
    with :ok <- id |> channels() |> :pg.leave(channel, pid),
         do: Antenna.Guard.remove(id, channel, pid)
  end
end
