# Smart Eventing

Antenna is an elegant event handling framework that combines the best features of Phoenix.PubSub and gen_event with sophisticated pattern matching and back-pressure control. Built on GenStage and fully distributed by design, it offers a powerful yet simple way to handle events across your Elixir applications.

## Key Features

### 1. Smart Pattern Matching

Unlike traditional pub/sub systems, Antenna provides Elixir-native pattern matching capabilities:

```elixir
# Match on complex patterns with guards
Antenna.match(MyApp.Antenna, 
  {:temperature, celsius, location} when celsius > 30,
  fn channel, event ->
    Logger.warning("High temperature alert: #{inspect(event)} on #{channel}")
  end,
  channels: [:sensors])
```

### 2. Built for Distribution

- Automatic event propagation across connected nodes
- Node-local pattern matching for efficiency
- Built-in back-pressure through GenStage
- Process group-based channel management

```elixir
# Events automatically propagate to all connected nodes
Node.connect(:"node2@host2")
Antenna.event(MyApp.Antenna, [:alerts], {:system_status, :degraded})
```

### 3. Flexible Event Handling

Support for both asynchronous and synchronous event processing:

```elixir
# Async event dispatch
Antenna.event(MyApp.Antenna, [:logs], {:user_action, user_id, :login})

# Sync event with collected responses
responses = Antenna.sync_event(MyApp.Antenna, [:auth], {:verify_token, token})
```

### 4. Channel-based Organization

- Multiple isolated Antenna instances
- Channel-based event routing
- Support for wildcard subscriptions
- Dynamic channel subscription management

```elixir
# Different antennas for different subsystems
Antenna.event(:metrics, [:system], %{cpu: 80, memory: 70})
Antenna.event(:business, [:orders], %{order_id: "123", status: :completed})
```

### 5. OTP-Compliant Design

- Follows OTP design principles
- Supervisor-based process management
- Clean process isolation
- Proper error handling and recovery

## Real-world Applications

### Event-Driven Microservices

```elixir
# Service A: Order Processing
Antenna.match(OrderSystem, 
  %{event: :order_created, total: total} when total > 1000,
  fn _, event ->
    HighValueOrderProcessor.handle(event)
  end,
  channels: [:orders])

# Service B: Notification System
Antenna.match(NotificationSystem,
  {:order_status, order_id, :completed},
  fn _, event ->
    CustomerNotifier.order_completed(order_id)
  end,
  channels: [:order_updates])
```

### IoT Data Processing

```elixir
# Device data handling with pattern matching
Antenna.match(IoTSystem,
  {:sensor_data, device_id, readings} when readings.temperature > 90,
  fn channel, event ->
    DeviceAlertHandler.process_alert(channel, event)
  end,
  channels: [:device_telemetry])
```

### Distributed Systems Monitoring

```elixir
# System metrics collection
Antenna.match(Monitoring,
  {:metric, node_name, metric, value} when value > threshold(),
  fn _, event ->
    MetricsAggregator.record_threshold_breach(event)
  end,
  channels: [:system_metrics])
```

## Getting Started

1. Add Antenna to your dependencies:

```elixir
def deps do
  [{:antenna, "~> 0.2"}]
end
```

2. Add it to your supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Antenna, name: MyApp.EventSystem}
    ]
    
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

3. Set up your event handlers:

```elixir
# Define matchers for your events
Antenna.match(MyApp.EventSystem,
  {:user_event, user_id, action},
  fn channel, event ->
    MyApp.EventTracker.track(channel, event)
  end,
  channels: [:user_activity])

# Start sending events
Antenna.event(MyApp.EventSystem, [:user_activity], 
  {:user_event, "user123", :login})
```

## Why Choose Antenna?

1. **Native Pattern Matching**: Leverage Elixir's powerful pattern matching for event handling
2. **Distributed by Design**: Built for distributed systems with automatic node synchronization
3. **Back-pressure Control**: Built on GenStage for controlled event flow
4. **Flexible Configuration**: Multiple isolated instances and channel-based routing
5. **Production Ready**: OTP-compliant with proper supervision and error handling

## Internal Architecture

### Event Flow

Antenna processes events through a distributed pipeline:

```txt
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

### Components

1. **Broadcaster (GenStage Producer)**
   - Distributes events to all nodes
   - Implements back-pressure control
   - Handles sync/async event dispatch

2. **Process Groups**
   - Channel-based process groups for event routing
   - Dynamic subscriber management
   - Node-local event matching

3. **Pattern Matchers**
   - Handle complex pattern matching
   - Support guards and conditions
   - Route events to appropriate handlers

4. **Guard**
   - Supervises channel subscriptions
   - Manages handler lifecycle
   - Ensures clean process termination

### Back-pressure

Antenna uses GenStage to implement back-pressure:

- Events are dispatched based on consumer demand
- System stays responsive under load
- Memory usage remains stable
- Event ordering is preserved

### Distribution

Built-in distribution capabilities:

- Automatic node discovery
- Transparent event propagation
- Node-local pattern matching
- Efficient event routing

For a detailed implementation guide and more examples, visit the [official documentation](https://hexdocs.pm/antenna).

## Configuration

Antenna can be configured in your `config.exs`:

```elixir
config :antenna,
  id: MyApp.Antenna,           # Optional custom identifier
  distributed: true,           # Enable distributed mode (default: true)
  sync_timeout: 5_000          # Default timeout for sync_event/4
```

## Best Practices

### 1. Channel Organization

- Use atoms for channel names when possible
- Group related events under common channels
- Consider using hierarchical channel naming:
  ```elixir
  # Good channel organization
  Antenna.event(MyApp.Antenna, [:users_created], event)
  Antenna.event(MyApp.Antenna, [:users_updated], event)
  ```

### 2. Pattern Matching

- Use specific patterns to avoid unnecessary matches:
  ```elixir
  # Good - specific pattern
  Antenna.match(MyApp.Antenna, {:user_created, user_id, meta}, handler)
  
  # Less efficient - overly broad pattern
  Antenna.match(MyApp.Antenna, {_action, _id, _}, handler)
  ```
- Include guards for more precise matching
- Consider the order of pattern matches when using multiple matchers

### 3. Handler Design

- Keep handlers focused and single-purpose
- Use `sync_event/4` only when you need responses
- Consider timeouts for sync operations:
  ```elixir
  # Set appropriate timeout for sync operations
  responses = Antenna.sync_event(MyApp.Antenna, [:auth], event, 10_000)
  ```
- Handle errors within handlers to prevent cascade failures

### 4. Performance

- Use async events (`event/3`) by default
- Keep handler processing time minimal
- Consider using separate processes for long-running operations:
  ```elixir
  Antenna.match(MyApp.Antenna, event_pattern, fn channel, event ->
    # Spawn long-running operations
    Task.start(fn -> LongRunningProcessor.process(event) end)
  end)
  ```
- Monitor matcher and handler counts

### 5. Testing

- Test matchers with various event patterns:
  ```elixir
  test "matches high temperature events" do
    Antenna.match(TestAntenna, 
      {:temperature, val, _} when val > 30,
      self(),
      channels: [:test])
      
    Antenna.event(TestAntenna, [:test], {:temperature, 35, :room})
    assert_receive {:antenna_event, :test, {:temperature, 35, :room}}
  end
  ```
- Test handler behavior with both valid and invalid events
- Test distributed scenarios
- Use ExUnit's `async: true` when possible

## Conclusion

Antenna provides a robust foundation for building distributed event-driven systems in Elixir. Whether you're building microservices, processing IoT data, or managing system events, Antenna offers the tools you need with the elegance and reliability you expect from Elixir applications.

