defmodule Antenna do
  @moduledoc """
  Documentation for `Antenna`.
  """

  alias Antenna.PubSub.Broadcaster

  @type id :: module()

  @type channel :: atom() | term()

  @type event :: term()

  @type handler :: (event() -> :ok) | (channel(), event() -> :ok) | pid() | GenServer.name()

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
  defmacro unmatch(id, match) do
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
  Sends an event to all the associated matchers
  """
  @spec event(id :: id(), channels :: channel() | [channel()], event :: event()) :: :ok
  def event(id \\ @id, channels, event),
    do: Broadcaster.sync_notify(Antenna.delivery(id), {List.wrap(channels), event})

  @spec join(id(), channel(), pid()) :: :ok | :already_joined
  defp join(id, channel, pid) do
    scope = channels(id)

    if pid not in :pg.get_members(scope, channel),
      do: :pg.join(scope, channel, pid),
      else: :already_joined
  end

  @spec leave(id(), channel(), pid()) :: :ok | :not_joined
  defp leave(id, channel, pid), do: id |> channels() |> :pg.leave(channel, pid)
end
