# DIY Message Broker

In Erlang (and Elixir), I always missed a way to organize “streaming” message exchange, similar to what a Message Broker provides. Normal developers accept the constraints imposed by their frameworks: Phoenix has [`PubSub`](https://hexdocs.pm/phoenix_pubsub/Phoenix.PubSub.html), OTP has [`:gen_event`](https://www.erlang.org/doc/apps/stdlib/gen_event.html), and Elixir had [`GenEvent`](https://hexdocs.pm/elixir/GenEvent.html), deprecated even before it was born.

None of these suited me. PubSub is powerful, but its asynchronicity is nailed down, and sometimes you need to call subscribers synchronously (I know you can send your pid with the message and wait for responses, but this ad-hoc approach unfortunately doesn’t help when the number of subscribers is unknown). `:gen_event` is almost what I need, but its design clearly exposes side-effect handlers, making convenient filtering of incoming message streams turn into spaghetti. In general, as always: if you don’t do it yourself, no one will.

Thus, the [`Antenna`](https://hexdocs.pm/antenna/) library was born, providing all the features usually achieved by adding an extra message broker dependency. My requirements for it were as follows:

- **Back pressure support out of the box** (a million events sent at once should not overwhelm handlers, and adding new nodes to the cluster should transparently offload them)
- **Channels (topics, tags)** where you can send an event that will be delivered to all registered handlers
- **Handlers (besides channel subscriptions)** should be able to transparently filter the incoming message stream using the full power of Erlang’s pattern matching
- **Both handlers and subscriptions** should successfully recover after a crash
- **The message sender can request synchronous execution** of handlers, blocking the calling process until all responses are received (like RPC)
- **The library should provide convenient primitives for testing its usage**

Anyone who has used [_RabbitMQ_](https://www.rabbitmq.com/tutorials) would have noticed where I stole my ideas from easily.

## Pseudocode

For a long time, I’ve used a kind of [_TDD_](https://en.wikipedia.org/wiki/Test-driven_development) with a hint of [_DDD_](https://en.wikipedia.org/wiki/Domain-driven_design), or vice versa—I’m not strong in buzzword abbreviations. In general, I start designing any piece of code by calling its (yet non-existent) API. First, I make sure that calling my code is easy and pleasant, and I’ll figure out the implementation later. So I sketched something like this:

```elixir
{:ok, pid} = match({:tag_answer, _}, self())
subscribe(:chan, pid)

event(:chan, {:tag_answer, 42})

receive do
  {:event, :chan, {:tag_answer, 42}} -> :ok
after
  1_000 -> :error
end
```


The first two lines are handler registration and subscription. The next is sending a message. The final block checks that the message was received. These three pieces will usually be in different, unrelated parts of the code.

The first thing I noticed is that the first two lines almost always go together, so it makes sense to accept a list of channels for subscription right in the “matcher” definition (without canceling the `subscribe/2` function, in case someone wants to subscribe to a channel later).

I also noticed that there can be many handlers, why not.

Thus, the unique identifier for a matcher remains the match itself. It can be quite tricky, so I chose its textual representation as the id (the string `"{:tag_answer, _}"` for the example above). I don’t really like this solution, but I don’t have a better one (yet). At least, inspecting matchers is much easier this way than, for example, using something hash-like.

So, we get a many-to-many relationship: many handlers for one match, which can receive messages from many channels. For example, we can subscribe to all messages of the form `{:error, _}` from all channels and assign two handlers: a logger will print to the console, telemetry will send something to Grafana, or wherever it’s customary to send everything.

## Main Architecture

Back pressure in Elixir implies using the [`GenStage`](https://hexdocs.pm/gen_stage) library. I already implemented my [`Throttler`](https://hexdocs.pm/finitomata/Finitomata.Throttler.html) with it, now it’s the broker’s turn. We remember about horizontal scaling—which means several consumers, at least one per node. Each consumer will send messages to specified channels, matchers will check if they need to bother (whether the message matches), and if so, call the handlers. Sounds reasonable.

I spread consumers across nodes using unnamed processes managed by [`DistributedSupervisor`](https://hexdocs.pm/distributed_supervisor/DistributedSupervisor.html), the broadcaster too (except this process is named, so there’s only one per cluster, and it will be restarted on another node if the current one disappears).

Each matcher is also a process, which stores a list of handlers and the match itself in its state. Here I faced my first architectural dilemma: how to store the match? `{:foo, _}` can’t just be stored as is; such code is only allowed as LHO in direct pattern matching calls, and storing its AST isn’t an option, because then you can’t insert it into a match. So, I decided to generate a matcher function (anyway, implementing `match/4` is only possible as a macro):

```elixir
quote generated: true, location: :keep do
  matcher = fn
    unquote(match) -> true
    _ -> false
  end
  …
end
```

Great. Now, in the matcher process itself, there’s a callback like this:

```elixir
  @impl GenServer
  @doc false
  def handle_cast({:handle_event, channel, event}, state) do
    if state.matcher.(event) do
      Enum.each(state.handlers, fn
        handler when is_function(handler, 1) -> handler.(event)
        handler when is_function(handler, 2) -> handler.(channel, event)
        process -> send(process, {:antenna_event, channel, event})
      end)
    end

    {:noreply, state}
  end
```

And we’re ready to send it messages from consumers (matchers are also managed by DistributedSupervisor, i.e., evenly spread across the cluster).

At this point, I said `git init` because the MVP was shaping up.

## Synchronous Call

Up to this point, everything was pretty trivial. But how do you organize a synchronous call when all messages go through seven circles of hell (broadcast, consumers, matchers-all on who-knows-which nodes in the cluster)?

Have you ever wondered why the signature of `GenServer`’s asynchronous callback is of arity `2`, while the synchronous one is of arity `3`? By the way, this is one of my favorite interview questions: it immediately becomes clear whether you’re dealing with a dreamy reactive hipster or a nerdy freaking sociopath.

The second argument in the [`handle_call/3`](https://hexdocs.pm/elixir/GenServer.html#c:handle_call/3) callback is the process identifier (without loss of generality) waiting for a synchronous response. And instead of the tuple `{:reply, result, state}` from this callback, you can return `{:noreply, new_state}`, and later send a synchronous reply directly to the calling process using [`GenServer.reply/2`](https://hexdocs.pm/elixir/GenServer.html#reply/2). If you didn’t know this, have a sip of whiskey for me: this is the hammer that makes everything around you nails.

`GenStage`, in turn, also exports `reply/2`. So now I just need to pass `from` through all consumers and matchers, and then deep inside write something like:

```elixir
Enum.each(results, fn
  {nil, _} -> :ok
  {from, results} -> GenStage.reply(from, results)
end)
```

If it was an asynchronous call-there’s no `from`, and we do nothing. But if it exists-we send back the accumulated results of all handler calls (and let it choke on them).

That seems to be all I wanted to share today. The link to the library, its source code, and tests are above.

Happy brokering!

