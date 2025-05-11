defmodule Antenna do
  @moduledoc """
  `Antenna` is a mixture of [`Phoenix.PubSub`](https://hexdocs.pm/phoenix_pubsub/Phoenix.PubSub.html)
    and [`:gen_event`](https://www.erlang.org/doc/apps/stdlib/gen_event.html) functionality
    with some batteries included.

  It implements back-pressure on top of `GenStage`, is fully conformant with
    [OTP Design Principles](https://www.erlang.org/doc/system/events). and
    is distributed out of the box.

  `Antenna` supports both asynchronous _and_ synchronous events. While the most preferrable way
    would be to stay fully async with `Antenna.event/3`, one still might propagate the event
    synchronously with `Antenna.sync_event/3` and collect all the responses from all the handlers.

  One can have as many isolated `Antenna`s as necessary, distinguished by `Antenna.t:id/0`.

  ## Getting Started

  To start using Antenna, add it to your dependencies in mix.exs:

  ```elixir
  def deps do
    [
      {:antenna, "~> 0.3.0"}
    ]
  end
  ```

  Then add it to your supervision tree:

  ```elixir
  defmodule MyApp.Application do
    use Application

    def start(_type, _args) do
      children = [
        Antenna
      ]

      opts = [strategy: :one_for_one, name: MyApp.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end
  ```

  ## Configuration

  Antenna can be configured in your config.exs:

  ```elixir
  config :antenna,
    id: MyApp.Antenna,           # Optional custom identifier
    distributed: true,           # Enable distributed mode (default: true)
    sync_timeout: 5_000          # Default timeout for sync_event/4
  ```

  ## Sequence Diagram

  ```mermaid
  sequenceDiagram
    Consumer->>+Broadcaster: sync_event(channel, event)
    Consumer->>+Broadcaster: event(channel, event) 
    Broadcaster-->>+Consumer@Node1: event
    Broadcaster-->>+Consumer@Node2: event
    Broadcaster-->>+Consumer@NodeN: event
    Consumer@Node1-->>-NoOp: mine?
    Consumer@NodeN-->>-NoOp: mine?
    Consumer@Node2-->>+Matchers: event
    Matchers-->>+Handlers: handle_match/2
    Matchers-->>+Handlers: handle_match/2
    Handlers->>-Consumer: response(to: sync_event)
  ```

  [ASCII representation](https://cascii.app/4164d).

  ## Common Use Cases

  ### Basic Event Handling

  ```elixir
  # Define a matcher for specific events
  Antenna.match(MyApp.Antenna, {:user_registered, user_id, _meta}, fn channel, event ->
    # Handle the event
    {:user_registered, user_id, meta} = event
    Logger.info("New user registered: \#{user_id} on channel \#{channel}")
    MyApp.UserNotifier.welcome(user_id)
  end, channels: [:user_events])

  # Send events
  Antenna.event(MyApp.Antenna, [:user_events], {:user_registered, "user123", %{source: "web"}})
  ```

  ### Error Handling

  ```elixir
  # Match on error events
  Antenna.match(MyApp.Antenna, {:error, reason, _context} = event, fn channel, event ->
    # Log and handle errors
    Logger.error("Error on channel \#{channel}: \#{inspect(event)}")
    MyApp.ErrorTracker.track(event)
  end, channels: [:errors])

  # Send error events
  Antenna.event(MyApp.Antenna, [:errors], {:error, :validation_failed, %{user_id: 123}})
  ```

  ### Distributed Setup

  Antenna automatically handles distribution when nodes are connected:

  ```elixir
  # On node1@host1
  Node.connect(:"node2@host2")
  Antenna.match(MyApp.Antenna, {:replicate, data}, fn _, {:replicate, data} ->
    MyApp.Storage.replicate(data)
  end, channels: [:replication])

  # On node2@host2
  Antenna.event(MyApp.Antenna, [:replication], {:replicate, some_data})
  # The event will be processed on both nodes
  ```

  ### Custom Matchers

  You can use pattern matching and guards in your matchers:

  ```elixir
  # Match on specific patterns with guards
  Antenna.match(MyApp.Antenna, 
    {:temperature, celsius, _} when celsius > 30,
    fn _, {:temperature, c, location} ->
      Logger.warning("High temperature (\#{c}°C) detected at \#{location}")
    end,
    channels: [:sensors])

  # Match on map patterns
  Antenna.match(MyApp.Antenna,
    %{event: :payment, amount: amount} when amount > 1000,
    fn _, event ->
      MyApp.LargePaymentProcessor.handle(event)
    end,
    channels: [:payments])
  ```

  ## Usage Example

  The consumer of this library is supposed to declare one or more matchers, subscribing to one
    or more channels, and then call `Antenna.event/2` to propagate the event.

  ```elixir
  assert {:ok, _pid, "{:tag_1, a, _} when is_nil(a)"} =
    Antenna.match(Antenna, {:tag_1, a, _} when is_nil(a), self(), channels: [:chan_1])

  assert :ok = Antenna.event(Antenna, [:chan_1], {:tag_1, nil, 42})
  assert_receive {:antenna_event, :chan_1, {:tag_1, nil, 42}}
  ```

  ## Architecture

  Antenna uses a distributed pub/sub architecture with the following components:

  1. **Broadcaster** - Handles event distribution across nodes
  2. **Matchers** - Pattern match on events and delegate to handlers
  3. **Guard** - Manages channel subscriptions and handler registration
  4. **PubSub** - Implements the core pub/sub functionality

  Events flow through the system as follows:

  1. Client calls `event/3` or `sync_event/4`
  2. Broadcaster distributes the event to all nodes
  3. Matchers on each node pattern match against the event
  4. Matching handlers process the event
  5. For sync_event, responses are collected and returned

  ## Best Practices

  1. **Channel Organization**
     - Use atoms for channel names
     - Group related events under common channels
     - Consider using hierarchical channel names (e.g., :users_created, :users_updated)

  2. **Pattern Matching**
     - Use specific patterns to avoid unnecessary pattern matches
     - Include guards for more precise matching
     - Consider the order of pattern matches when using multiple matchers

  3. **Handler Design**
     - Keep handlers focused and single-purpose
     - Use `sync_event/4` when you need responses
     - Consider timeouts for sync operations
     - Handle errors within handlers to prevent cascade failures

  4. **Performance**
     - Use async events (`event/3`) when possible
     - Keep handler processing time minimal
     - Consider using separate processes for long-running operations
     - Monitor matcher and handler counts

  5. **Testing**
     - Test matchers with various event patterns
     - Verify handler behavior
     - Test distributed scenarios
     - Use ExUnit's async: true when possible
  """

  require Logger
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
  @type handler :: (event() -> term()) | (channel(), event() -> term()) | Antenna.Matcher.t() | pid() | GenServer.name()

  @typedoc """
  The options to be passed to `Antenna.match/4` and `Antenna.unmatch/2`

  * `:id` - the identifier of the `Antenna`, defaults to `Antenna`
  * `:channels` - a list of channels to subscribe the matcher to
  * `:once?` - if true, the matcher would be removed after the first match
  """
  @type opts :: [id: id(), channels: channel() | [channel()], once?: boolean()]

  @typedoc """
  The matcher to be used for the event, e.g. `{:tag_1, a, _} when is_nil(a)`

  The pattern matching is done on the `Antenna` process, so it might be
    either a function or a process id.
  """
  @type matcher :: term()

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

  # Supervision tree
  use Supervisor

  @doc """
  Starts the `Antenna` matcher tree for the `id` given. 
  """
  @doc section: :setup
  @spec start_link([{:id, atom()}]) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    init_arg = if Keyword.keyword?(init_arg), do: Keyword.get_lazy(init_arg, :id, &id/0), else: init_arg
    Supervisor.start_link(__MODULE__, init_arg, name: init_arg)
  end

  @impl Supervisor
  @doc false
  def init(id) do
    children = [
      %{id: :pg, start: {__MODULE__, :start_pg, [Antenna.channels(id)]}},
      {Antenna.Guard, id: id},
      {Antenna.PubSub, id: id},
      {DistributedSupervisor, name: Antenna.matchers(id), monitor_nodes: true}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns a specification to start this module under a supervisor.

  See `Supervisor`.
  """
  @doc section: :setup
  def child_spec(init_arg), do: super(init_arg)

  @doc false
  @spec start_pg(module()) :: {:ok, pid()} | :ignore
  def start_pg(scope) do
    with {:error, {:already_started, _pid}} <- :pg.start_link(scope), do: :ignore
  end

  @doc false
  defmacro lookup(id \\ @id, match) do
    name = with ast when not is_binary(ast) <- match, do: Macro.to_string(ast)
    quote generated: true, location: :keep, do: {unquote(name), Antenna.whereis(unquote(id), unquote(name))}
  end

  @doc """
  Declares a matcher for tagged events.

  This function sets up a pattern matcher to handle specific events on the given channels.
  When an event matching the pattern is sent to any of the channels, the provided handler
  will be invoked.

  ## Options

  * `:channels` - A list of channels to subscribe this matcher to
  * `:once?` - If true, the matcher will be automatically unmatched after the first match (default: false)

  ## Examples

  ### Basic Usage

  ```elixir
  Antenna.match(Antenna, %{tag: _, success: false}, fn channel, message ->
    Logger.warning("The processing failed for [" <> 
      inspect(channel) <> "], result: " <> inspect(message))
  end, channels: [:rabbit])
  ```

  ### One-time Matcher

  ```elixir
  # This matcher will only trigger once and then be removed
  Antenna.match(Antenna, {:init, pid}, fn _, {:init, pid} ->
    send(pid, :initialized)
  end, channels: [:system], once?: true)
  ```

  ### Using Pattern Guards

  ```elixir
  Antenna.match(Antenna, 
    {:metric, name, value} when value > 100, 
    fn channel, event ->
      Logger.info("High metric value on \#{channel}: \#{inspect(event)}")
    end, 
    channels: [:metrics])
  ```

  ### Multiple Channels

  ```elixir
  Antenna.match(Antenna, 
    {:user_event, user_id, _action},
    fn channel, event ->
      # Handle user events from multiple channels
      MyApp.UserEventTracker.track(channel, event)
    end,
    channels: [:user_logins, :user_actions, :user_settings])
  ```
  """
  @doc section: :setup
  defmacro match(id \\ @id, match, handlers, opts \\ [])

  defmacro match(id, match, handlers, opts) do
    name = Macro.to_string(match)

    quote generated: true, location: :keep do
      matcher = fn
        unquote(match) -> true
        _ -> false
      end

      opts = unquote(opts)

      with {:ok, pid, name} <-
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
             ) do
        # Antenna.handle(unquote(id), unquote(handlers), pid)
        unquote(handlers) |> List.wrap() |> Enum.each(&Antenna.Guard.add_handler(unquote(id), &1, pid))

        {:ok, pid, name}
      end
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
  @doc section: :setup
  defmacro unmatch(id \\ @id, match) do
    quote generated: true, location: :keep do
      with pid when is_pid(pid) <- Antenna.whereis(unquote(id), unquote(match)) do
        Antenna.unhandle_all(unquote(id), pid)
        DistributedSupervisor.terminate_child(Antenna.matchers(unquote(id)), pid)
      end
    end
  end

  @doc false
  @doc section: :setup
  defmacro attach(id \\ @id, channels, match) do
    quote generated: true, location: :keep do
      with pid when is_pid(pid) <- Antenna.whereis(unquote(id), unquote(match)),
           do: Antenna.subscribe(unquote(id), unquote(channels), pid)
    end
  end

  @doc false
  @doc section: :setup
  defmacro unattach(id \\ @id, channels, match) do
    quote generated: true, location: :keep do
      with pid when is_pid(pid) <- Antenna.whereis(unquote(id), unquote(match)),
           do: Antenna.unsubscribe(unquote(id), unquote(channels), pid)
    end
  end

  @doc """
  Subscribes a matcher process specified by `pid` to a channel(s)
  """
  @doc section: :setup
  @spec subscribe(id :: id(), channels :: channel() | [channel()], pid()) :: :ok
  def subscribe(id \\ @id, channels, pid)

  def subscribe(_, [], _), do: :ok

  def subscribe(id, channels, pid) when is_pid(pid) do
    channels
    |> List.wrap()
    |> Enum.each(&join(id, &1, pid))
  end

  def subscribe(id, channels, pid),
    do: Logger.warning("Unexpected subscription: " <> inspect(id: id, channels: channels, pid: pid))

  @doc """
  Unsubscribes a previously subscribed matcher process specified by `pid` from the channel(s)
  """
  @doc section: :setup
  @spec unsubscribe(id :: id(), channels :: channel() | [channel()], pid()) :: :ok
  def unsubscribe(id \\ @id, channels, pid)

  def unsubscribe(_, [], _), do: :ok

  def unsubscribe(id, channels, pid) when is_pid(pid) do
    channels
    |> List.wrap()
    |> Enum.each(&leave(id, &1, pid))
  end

  @doc """
  Adds a handler to the matcher process specified by `pid`
  """
  @doc section: :setup
  @spec handle(id :: id(), handlers :: handler() | [handler()], pid()) :: :ok
  def handle(id \\ @id, handlers, pid)

  def handle(_, [], _), do: :ok

  def handle(id, handlers, pid) when is_pid(pid) do
    handlers
    |> List.wrap()
    |> Enum.each(&do_handle(id, &1, pid))
  end

  @doc false
  @spec unhandle_all(id :: id(), pid()) :: :ok
  def unhandle_all(id \\ @id, pid), do: do_unhandle(id, pid)

  @doc """
  Removes a handler from the matcher process specified by `pid`
  """
  @doc section: :setup
  @spec unhandle(id :: id(), handlers :: handler() | [handler()], pid()) :: :ok
  def unhandle(id \\ @id, handlers, pid)

  def unhandle(_, [], _), do: :ok

  def unhandle(id, handlers, pid) when is_pid(pid) do
    handlers
    |> List.wrap()
    |> Enum.each(&do_unhandle(id, &1, pid))
  end

  @doc false
  @doc section: :internals
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

  If one wants to collect results of all the registered event handlers,
    they should look at `sync_event/3` instead.

  ## Examples

  ### Basic Usage

  ```elixir
  # Send event to a single channel
  Antenna.event(MyApp.Antenna, :user_events, {:user_logged_in, "user123"})

  # Send event to multiple channels
  Antenna.event(MyApp.Antenna, [:logs, :metrics], {:api_call, "/users", 200, 45})

  # Send event to all channels
  Antenna.event(MyApp.Antenna, :*, {:system_notification, :service_starting})
  ```

  ### Custom Antenna ID

  ```elixir
  # Using a specific Antenna instance
  Antenna.event(MyBackgroundJobs.Antenna, :jobs, {:job_completed, "job-123"})
  ```
  """
  @doc section: :client
  @spec event(id :: id(), channels :: channel() | [channel()], event :: event()) :: :ok
  def event(id \\ @id, channels, event),
    do: Broadcaster.async_notify(Antenna.delivery(id), {List.wrap(channels), event})

  @doc """
  Sends an event to all the associated matchers through channels synchronously,
  collecting and returning responses from all handlers.

  The special `:*` might be specified as channels, then the event
  will be sent to all the registered channels.

  Unlike `event/3`, this function waits for all handlers to process the event
  and returns their responses.

  ## Parameters

  * `id` - The Antenna instance identifier (optional, defaults to configured value)
  * `channels` - Single channel or list of channels to send the event to
  * `event` - The event to be sent
  * `timeout` - Maximum time to wait for responses (default: 5000ms)

  ## Examples

  ### Basic Usage

  ```elixir
  # Send sync event and collect responses
  results = Antenna.sync_event(MyApp.Antenna, :user_events, {:verify_user, "user123"})

  # Send to multiple channels with custom timeout
  results = Antenna.sync_event(
    MyApp.Antenna,
    [:validations, :security],
    {:user_action, "user123", :delete_account},
    10_000
  )
  ```

  ### Response Format

  The function returns a list of handler responses, each wrapped in a tuple
  indicating whether the pattern matched and including the handler's result:

  ```elixir
  [
    {:match, %{
      match: "pattern_string",
      channel: :channel_name,
      results: [handler_result]
    }},
    {:no_match, :channel_name}
  ]
  ```
  """
  @doc section: :client
  @spec sync_event(id :: id(), channels :: channel() | [channel()], event :: event(), timeout :: timeout()) :: [term()]
  def sync_event(id \\ @id, channels, event, timeout \\ 5_000),
    do: Broadcaster.sync_notify(Antenna.delivery(id), {List.wrap(channels), event}, timeout)

  @doc """
  Returns a map of matches to matchers
  """
  @doc section: :internals
  @spec registered_matchers(id :: id()) :: %{term() => {pid(), Supervisor.child_spec()}}
  def registered_matchers(id),
    do: id |> Antenna.matchers() |> DistributedSupervisor.children()

  @spec join(id(), channel(), pid()) :: :ok | :already_joined
  defp join(id, channel, pid) do
    scope = channels(id)

    if pid in :pg.get_members(scope, channel) do
      :already_joined
    else
      :ok = Antenna.Guard.add_channel(id, channel, pid)
      :pg.join(scope, channel, pid)
    end
  end

  @spec leave(id(), channel(), pid()) :: :ok | :not_joined
  defp leave(id, channel, pid) do
    with :ok <- id |> channels() |> :pg.leave(channel, pid),
         do: Antenna.Guard.remove_channel(id, channel, pid)
  end

  @spec do_handle(id(), handler(), pid()) :: :ok
  defp do_handle(id, handler, pid) do
    Antenna.Guard.add_handler(id, handler, pid)
    GenServer.cast(pid, {:add_handler, handler})
  end

  @spec do_unhandle(id(), pid()) :: :ok
  defp do_unhandle(id, pid) do
    Antenna.Guard.remove_all_handlers(id, pid)
    GenServer.cast(pid, :remove_all_handlers)
  end

  @spec do_unhandle(id(), handler(), pid()) :: :ok
  defp do_unhandle(id, handler, pid) do
    Antenna.Guard.remove_handler(id, handler, pid)
    GenServer.cast(pid, {:remove_handler, handler})
  end
end
