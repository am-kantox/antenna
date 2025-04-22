# Antenna

**The tiny framework to simplify work with events, based on `GenStage`**

## Objective

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

The workflow looks like shown below.

### Flow

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

[ASCII representation](https://cascii.app/4164d).

### Usage Example

The consumer of this library is supposed to declare one or more matchers, subscribing to one
or more channels, and then call `Antenna.event/2` to propagate the event.


## Installation

```elixir
def deps do
  [
    {:antenna, "~> 0.2"}
  ]
end
```

## Is it of any good?

Sure, it is.

## [Documentation](https://hexdocs.pm/antenna)

