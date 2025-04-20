defmodule Antenna do
  @moduledoc """
  Documentation for `Antenna`.
  """

  alias Antenna.PubSub.Broadcaster

  @type match :: Macro.t()

  @type matcher :: reference()

  @type tag :: term()

  @type event :: {tag(), term()} | Macro.t() | term()

  @type handler :: (event() -> :ok) | pid() | GenServer.name()

  @delivery Application.compile_env(:antenna, :delivery, Antenna.Delivery)
  @matchers Application.compile_env(:antenna, :matchers, Antenna.Matchers)
  @tags Application.compile_env(:antenna, :tags, Antenna.Tags)
  @groups Application.compile_env(:antenna, :groups, Antenna.Groups)

  @doc false
  def delivery, do: @delivery
  @doc false
  def matchers, do: @matchers
  @doc false
  def tags, do: @tags
  @doc false
  def groups, do: @groups

  @doc false
  def id_opts(%{id: id} = opts), do: {id, Map.delete(opts, :id)}
  def id_opts(%{name: id} = opts), do: {id, Map.delete(opts, :name)}

  def id_opts(opts) do
    if Keyword.keyword?(opts),
      do: Keyword.pop_lazy(opts, :id, fn -> Keyword.get(opts, :name, __MODULE__) end),
      else: {opts, []}
  end

  @doc """
  The simple matcher for tagged events.

  @spec match(tags :: tag() | [tag()], event :: event(), handler :: handler() | [handler()]) ::
          DynamicSupervisor.on_start_child()
  """
  defmacro match(match, tags \\ [], handler)

  defmacro match(match, tags, handlers) do
    name = Macro.to_string(match)

    quote generated: true, location: :keep do
      matcher = fn
        unquote(match) -> true
        _ -> false
      end

      DistributedSupervisor.start_child(
        unquote(matchers()),
        {Antenna.Matcher,
         name: unquote(name), matcher: matcher, handlers: List.wrap(unquote(handlers)), tags: List.wrap(unquote(tags))}
      )
    end
  end

  @doc """
  Attaches a matcher process specified by `pid` to a tag
  """
  @spec attach(tags :: tag() | [tag()], pid() | event()) :: :ok | :error
  def attach([], _), do: :ok

  def attach(tags, pid) when is_pid(pid) do
    tags
    |> List.wrap()
    |> Enum.each(&join(&1, pid))
  end

  def attach(tags, event) do
    case whereis(event) do
      nil -> :error
      pid when is_pid(pid) -> attach(tags, pid)
    end
  end

  @doc """
  Looks up the process associated with the event definition
  """
  @spec whereis(event :: event()) :: nil | pid()
  def whereis(event) do
    event = fix_event(event)

    case DistributedSupervisor.children(matchers()) do
      %{^event => {pid, _spec}} when is_pid(pid) -> pid
      _ -> nil
    end
  end

  @doc """
  Sends an event to all the associated matchers
  """
  @spec event(tags :: tag() | [tag()], event :: event()) :: :ok
  def event(tags, event), do: Broadcaster.sync_notify(Antenna.delivery(), {List.wrap(tags), event})

  defp fix_event({atom, meta, args}) when is_atom(atom) and is_list(meta) and is_list(args), do: {atom, meta, args}

  defp fix_event(event) do
    event =
      event
      |> Macro.escape()
      |> Macro.postwalk(fn
        {:_, _, _} = quoted -> quoted
        :_ -> Macro.var(:_, __ENV__.context)
        other -> other
      end)

    quote(do: unquote(event))
  end

  defp join(tag, pid) do
    scope = tags()
    if pid not in :pg.get_members(scope, tag), do: :pg.join(scope, tag, pid)
  end
end
