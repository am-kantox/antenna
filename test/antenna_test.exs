defmodule Antenna.Test do
  use ExUnit.Case, async: true
  doctest Antenna

  alias Antenna.Test.Matcher

  @antenna __MODULE__.ID

  setup_all ctx do
    Map.put(ctx, :antenna_pid, start_supervised!({Antenna, id: @antenna}))
  end

  test "straight single node (async)" do
    assert {:ok, pid1, "{:tag_antenna_1, a, _} when is_nil(a)"} =
             Antenna.match(@antenna, {:tag_antenna_1, a, _} when is_nil(a), self(), channels: [:chan_antenna_1])

    assert :ok = Antenna.event(@antenna, [:chan_antenna_1], {:tag_antenna_1, nil, 42})
    assert_receive {:antenna_event, :chan_antenna_1, {:tag_antenna_1, nil, 42}}, 1_000

    assert %Antenna.Guard{groups: %{chan_antenna_1: pids}} = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
    assert 1 = MapSet.size(pids)

    assert {:ok, pid2, "{:tag_antenna_1, _}"} =
             Antenna.match(@antenna, {:tag_antenna_1, _}, [Matcher, self()], channels: [:chan_antenna_1])

    assert :ok = Antenna.event(@antenna, [:chan_antenna_1], {:tag_antenna_1, 42})
    assert_receive {:antenna_event, :chan_antenna_1, {:tag_antenna_1, 42}}, 1_000

    assert %{"{:tag_antenna_1, a, _} when is_nil(a)" => {^pid1, _}, "{:tag_antenna_1, _}" => {^pid2, _}} =
             Antenna.registered_matchers(@antenna)

    assert %Antenna.Guard{groups: %{chan_antenna_1: pids}} = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
    assert ^pids = MapSet.new([pid1, pid2])
    assert :ok = Antenna.unmatch(@antenna, {:tag_antenna_1, a, _} when is_nil(a))

    assert :ok = Antenna.event(@antenna, [:chan_antenna_1], {:tag_antenna_1, 42})
    assert_receive {:antenna_event, :chan_antenna_1, {:tag_antenna_1, 42}}
    assert :ok = Antenna.event(@antenna, [:chan_antenna_1], {:tag_antenna_1, :chan_antenna_1, 42})
    refute_receive {:antenna_event, _, _}

    assert %Antenna.Guard{groups: %{chan_antenna_1: pids}} = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
    assert ^pids = MapSet.new([pid2])
  end

  test "once?: true" do
    assert {:ok, pid1, "{:tag_2, _}"} = Antenna.match(@antenna, {:tag_2, _}, self(), channels: [:chan_2], once?: true)

    assert %{"{:tag_2, _}" => {^pid1, %{id: Antenna.Matcher}}} =
             DistributedSupervisor.children(Antenna.matchers(@antenna))

    assert :ok = Antenna.event(@antenna, :chan_2, {:tag_2, 42})
    assert_receive {:antenna_event, :chan_2, {:tag_2, 42}}, 1_000
    Process.sleep(100)

    refute Map.has_key?(DistributedSupervisor.children(Antenna.matchers(@antenna)), "{:tag_2, _}")
  end

  test "straight single node (sync)" do
    assert {:ok, pid1, "{:tag_3, a, _} when is_nil(a)"} =
             Antenna.match(@antenna, {:tag_3, a, _} when is_nil(a), self(), channels: [:chan_3])

    assert [
             match: %{
               match: "{:tag_3, a, _} when is_nil(a)",
               pid: ^pid1,
               channel: :chan_3,
               results: [{:antenna_event, :chan_3, {:tag_3, nil, 42}}]
             }
           ] = Antenna.sync_event(@antenna, [:chan_3], {:tag_3, nil, 42})

    assert_receive {:antenna_event, :chan_3, {:tag_3, nil, 42}}

    assert %Antenna.Guard{groups: %{chan_3: pids}} = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
    assert 1 = MapSet.size(pids)

    assert {:ok, pid2, "{:tag_3, _}"} = Antenna.match(@antenna, {:tag_3, _}, self(), channels: [:chan_3])

    assert [
             {:no_match, :chan_3},
             {:match, %{match: "{:tag_3, _}", channel: :chan_3, results: [{:antenna_event, :chan_3, {:tag_3, 42}}]}}
           ] = Antenna.sync_event(@antenna, [:chan_3], {:tag_3, 42})

    assert_receive {:antenna_event, :chan_3, {:tag_3, 42}}

    assert %Antenna.Guard{groups: %{chan_3: pids}} = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
    assert ^pids = MapSet.new([pid1, pid2])
    assert :ok = Antenna.unmatch(@antenna, {:tag_3, a, _} when is_nil(a))

    assert [
             match: %{
               match: "{:tag_3, _}",
               pid: ^pid2,
               channel: :chan_3,
               results: [{:antenna_event, :chan_3, {:tag_3, 42}}]
             }
           ] = Antenna.sync_event(@antenna, [:chan_3], {:tag_3, 42})

    assert_receive {:antenna_event, :chan_3, {:tag_3, 42}}
    assert [{:no_match, :chan_3}] = Antenna.sync_event(@antenna, [:chan_3], {:tag_3, :chan_3, 42})
    refute_receive {:antenna_event, _, _}

    assert %Antenna.Guard{groups: %{chan_3: pids}} = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
    assert ^pids = MapSet.new([pid2])
  end

  test "multi-channel event broadcasting" do
    test_pid = self()

    # Set up a matcher subscribed to multiple channels
    assert {:ok, pid1, "{:multi_channel_event, _}"} =
             Antenna.match(
               @antenna,
               {:multi_channel_event, _},
               fn channel, event ->
                 send(test_pid, {:from_handler, channel, event})
               end,
               channels: [:channel_a, :channel_b, :channel_c]
             )

    # Test broadcasting to a specific channel
    assert :ok = Antenna.event(@antenna, :channel_a, {:multi_channel_event, "test A"})
    assert_receive {:from_handler, :channel_a, {:multi_channel_event, "test A"}}, 1_000

    # Test broadcasting to a different channel
    assert :ok = Antenna.event(@antenna, :channel_b, {:multi_channel_event, "test B"})
    assert_receive {:from_handler, :channel_b, {:multi_channel_event, "test B"}}, 1_000

    # Test broadcasting to multiple channels simultaneously
    assert :ok = Antenna.event(@antenna, [:channel_a, :channel_c], {:multi_channel_event, "test AC"})
    assert_receive {:from_handler, :channel_a, {:multi_channel_event, "test AC"}}, 1_000
    assert_receive {:from_handler, :channel_c, {:multi_channel_event, "test AC"}}, 1_000

    # Verify the matcher is subscribed to all channels
    guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))

    assert %{channel_a: pids_a, channel_b: pids_b, channel_c: pids_c} = guard_state.groups
    assert MapSet.member?(pids_a, pid1)
    assert MapSet.member?(pids_b, pid1)
    assert MapSet.member?(pids_c, pid1)
  end

  test "complex pattern matching with maps and guards" do
    test_pid = self()

    # Map pattern matcher
    assert {:ok, map_pid, "%{event_type: :map_event, value: value} when value > 100"} =
             Antenna.match(
               @antenna,
               %{event_type: :map_event, value: value} when value > 100,
               fn _, event -> send(test_pid, {:map_match, event}) end,
               channels: [:complex_channel]
             )

    assert is_pid(map_pid)

    # Nested pattern matcher with complex guard
    assert {:ok, nested_pid, "{:nested, %{id: id, data: data}} when is_binary(id) and length(data) > 2"} =
             Antenna.match(
               @antenna,
               {:nested, %{id: id, data: data}} when is_binary(id) and length(data) > 2,
               fn _, event -> send(test_pid, {:nested_match, event}) end,
               channels: [:complex_channel]
             )

    assert is_pid(nested_pid)

    # Should match the map pattern (value > 100)
    assert :ok = Antenna.event(@antenna, :complex_channel, %{event_type: :map_event, value: 150})
    assert_receive {:map_match, %{event_type: :map_event, value: 150}}, 1_000

    # Should not match the map pattern (value <= 100)
    assert :ok = Antenna.event(@antenna, :complex_channel, %{event_type: :map_event, value: 50})
    refute_receive {:map_match, _}, 100

    # Should match the nested pattern
    assert :ok = Antenna.event(@antenna, :complex_channel, {:nested, %{id: "test-123", data: [1, 2, 3, 4]}})
    assert_receive {:nested_match, {:nested, %{id: "test-123", data: [1, 2, 3, 4]}}}, 1_000

    # Should not match the nested pattern (data length <= 2)
    assert :ok = Antenna.event(@antenna, :complex_channel, {:nested, %{id: "test-123", data: [1, 2]}})
    refute_receive {:nested_match, {:nested, %{data: [1, 2]}}}, 100

    # Should not match the nested pattern (id not binary)
    assert :ok = Antenna.event(@antenna, :complex_channel, {:nested, %{id: 123, data: [1, 2, 3, 4]}})
    refute_receive {:nested_match, {:nested, %{id: 123}}}, 100

    # Clean up
    assert :ok = Antenna.unmatch(@antenna, %{event_type: :map_event, value: value} when value > 100)
    assert :ok = Antenna.unmatch(@antenna, {:nested, %{id: id, data: data}} when is_binary(id) and length(data) > 2)
  end

  test "handler management" do
    test_pid = self()

    # Create a simple matcher with no handlers initially
    assert {:ok, matcher_pid, "{:handler_test, _}"} =
             Antenna.match(
               @antenna,
               {:handler_test, _},
               [],
               channels: [:handler_channel]
             )

    # Event should not be processed (no handlers)
    assert :ok = Antenna.event(@antenna, :handler_channel, {:handler_test, "no handler"})
    refute_receive {:handler_called, _}, 100

    # Add a handler
    handler1 = fn _, event -> send(test_pid, {:handler_called, 1, event}) end
    assert :ok = Antenna.handle(@antenna, handler1, matcher_pid)

    # Now the event should be processed by handler1
    assert :ok = Antenna.event(@antenna, :handler_channel, {:handler_test, "handler1"})
    assert_receive {:handler_called, 1, {:handler_test, "handler1"}}, 1_000

    # Add a second handler
    handler2 = fn _, event -> send(test_pid, {:handler_called, 2, event}) end
    assert :ok = Antenna.handle(@antenna, handler2, matcher_pid)

    # Now the event should be processed by both handlers
    assert :ok = Antenna.event(@antenna, :handler_channel, {:handler_test, "both handlers"})
    assert_receive {:handler_called, 1, {:handler_test, "both handlers"}}, 1_000
    assert_receive {:handler_called, 2, {:handler_test, "both handlers"}}, 1_000

    # Remove the first handler
    assert :ok = Antenna.unhandle(@antenna, handler1, matcher_pid)

    # Now the event should only be processed by handler2
    assert :ok = Antenna.event(@antenna, :handler_channel, {:handler_test, "only handler2"})
    refute_receive {:handler_called, 1, _}, 100
    assert_receive {:handler_called, 2, {:handler_test, "only handler2"}}, 1_000

    # Remove all handlers
    assert :ok = Antenna.unhandle_all(@antenna, matcher_pid)

    # Now no events should be processed
    assert :ok = Antenna.event(@antenna, :handler_channel, {:handler_test, "no handlers again"})
    refute_receive {:handler_called, _, _}, 100

    # Clean up
    assert :ok = Antenna.unmatch(@antenna, {:handler_test, _})
  end

  test "special :* channel broadcasting" do
    test_pid = self()

    # Set up matchers on different channels
    assert {:ok, pid1, "{:star_event, target: " <> _} =
             Antenna.match(
               @antenna,
               {:star_event, target: target} when target in [:channel_x, :all, :sync_all],
               fn channel, event -> send(test_pid, {:star_received, :channel_x, channel, event}) end,
               channels: [:channel_x]
             )

    assert is_pid(pid1)

    assert {:ok, pid2, "{:star_event, target: " <> _} =
             Antenna.match(
               @antenna,
               {:star_event, target: target} when target in [:channel_y, :all, :sync_all],
               fn channel, event -> send(test_pid, {:star_received, :channel_y, channel, event}) end,
               channels: [:channel_y]
             )

    assert is_pid(pid2)

    assert {:ok, pid3, "{:star_event, target: " <> _} =
             Antenna.match(
               @antenna,
               {:star_event, target: target} when target in [:channel_z, :all, :sync_all],
               fn channel, event -> send(test_pid, {:star_received, :channel_z, channel, event}) end,
               channels: [:channel_z]
             )

    assert is_pid(pid3)

    # Test specific channel event delivery
    assert :ok = Antenna.event(@antenna, :channel_y, {:star_event, target: :channel_y})
    assert_receive {:star_received, :channel_y, :channel_y, {:star_event, target: :channel_y}}, 1_000
    refute_receive {:star_received, :channel_x, _, _}, 100
    refute_receive {:star_received, :channel_z, _, _}, 100

    # Test broadcasting to all channels using :*
    assert :ok = Antenna.event(@antenna, :*, {:star_event, target: :all})

    # All matchers should receive the event on their respective channels
    assert_receive {:star_received, :channel_x, :channel_x, {:star_event, target: :all}}, 1_000
    assert_receive {:star_received, :channel_y, :channel_y, {:star_event, target: :all}}, 1_000
    assert_receive {:star_received, :channel_z, :channel_z, {:star_event, target: :all}}, 1_000

    # Test sync event with :*
    results = Antenna.sync_event(@antenna, :*, {:star_event, target: :sync_all})

    # Verify all handlers processed the event
    assert length(Keyword.take(results, [:match])) == 3

    # Each handler should have received the event
    assert_receive {:star_received, :channel_x, :channel_x, {:star_event, target: :sync_all}}, 1_000
    assert_receive {:star_received, :channel_y, :channel_y, {:star_event, target: :sync_all}}, 1_000
    assert_receive {:star_received, :channel_z, :channel_z, {:star_event, target: :sync_all}}, 1_000

    # Clean up
    refute Antenna.unmatch(@antenna, {:star_event, target: :channel_x})
    refute Antenna.unmatch(@antenna, {:star_event, target: :channel_y})
    refute Antenna.unmatch(@antenna, {:star_event, target: :channel_z})
  end

  test "channel subscription and unsubscription" do
    test_pid = self()

    # Create a matcher without specifying channels initially
    assert {:ok, sub_pid, "{:subscription_test, _}"} =
             Antenna.match(
               @antenna,
               {:subscription_test, _},
               fn channel, event -> send(test_pid, {:sub_event, channel, event}) end,
               channels: []
             )

    # Event should not be received (not subscribed to any channel)
    assert :ok = Antenna.event(@antenna, :sub_channel_1, {:subscription_test, 1})
    refute_receive {:sub_event, _, _}, 100

    # Subscribe to channel 1
    assert :ok = Antenna.subscribe(@antenna, :sub_channel_1, sub_pid)

    # Now should receive events on channel 1
    assert :ok = Antenna.event(@antenna, :sub_channel_1, {:subscription_test, 2})
    assert_receive {:sub_event, :sub_channel_1, {:subscription_test, 2}}, 1_000

    # Subscribe to channel 2
    assert :ok = Antenna.subscribe(@antenna, :sub_channel_2, sub_pid)

    # Now should receive events on both channels
    assert :ok = Antenna.event(@antenna, :sub_channel_1, {:subscription_test, 3})
    assert :ok = Antenna.event(@antenna, :sub_channel_2, {:subscription_test, 4})
    assert_receive {:sub_event, :sub_channel_1, {:subscription_test, 3}}, 1_000
    assert_receive {:sub_event, :sub_channel_2, {:subscription_test, 4}}, 1_000

    # Subscribe to multiple channels at once
    assert :ok = Antenna.subscribe(@antenna, [:sub_channel_3, :sub_channel_4], sub_pid)

    # Should receive events on all subscribed channels
    assert :ok = Antenna.event(@antenna, :sub_channel_3, {:subscription_test, 5})
    assert :ok = Antenna.event(@antenna, :sub_channel_4, {:subscription_test, 6})
    assert_receive {:sub_event, :sub_channel_3, {:subscription_test, 5}}, 1_000
    assert_receive {:sub_event, :sub_channel_4, {:subscription_test, 6}}, 1_000

    # Unsubscribe from channel 1
    assert :ok = Antenna.unsubscribe(@antenna, :sub_channel_1, sub_pid)

    # Should no longer receive events on channel 1
    assert :ok = Antenna.event(@antenna, :sub_channel_1, {:subscription_test, 7})
    refute_receive {:sub_event, :sub_channel_1, _}, 100

    # Should still receive events on other channels
    assert :ok = Antenna.event(@antenna, :sub_channel_2, {:subscription_test, 8})
    assert_receive {:sub_event, :sub_channel_2, {:subscription_test, 8}}, 1_000

    # Unsubscribe from multiple channels at once
    assert :ok = Antenna.unsubscribe(@antenna, [:sub_channel_3, :sub_channel_4], sub_pid)

    # Should no longer receive events on channels 3 and 4
    assert :ok = Antenna.event(@antenna, :sub_channel_3, {:subscription_test, 9})
    assert :ok = Antenna.event(@antenna, :sub_channel_4, {:subscription_test, 10})
    refute_receive {:sub_event, :sub_channel_3, _}, 100
    refute_receive {:sub_event, :sub_channel_4, _}, 100

    # Clean up
    assert :ok = Antenna.unmatch(@antenna, {:subscription_test, _})
  end

  test "sync event timeout handling" do
    test_pid = self()

    # Create a matcher with a handler that sleeps longer than the timeout
    assert {:ok, timeout_pid, "{:timeout_test, _}"} =
             Antenna.match(
               @antenna,
               {:timeout_test, _},
               fn channel, event ->
                 # Sleep longer than the timeout to simulate slow processing
                 :timer.sleep(300)
                 send(test_pid, {:timeout_handler_completed, channel, event})
                 {:ok, :handler_response}
               end,
               channels: [:timeout_channel]
             )

    assert is_pid(timeout_pid)

    # Using a very short timeout (100ms) should result in timeout
    try do
      Antenna.sync_event!(@antenna, :timeout_channel, {:timeout_test, "should timeout"}, 100)
    catch
      :exit, reason ->
        assert reason ==
                 {:timeout,
                  {GenServer, :call,
                   [
                     {:via, DistributedSupervisor.Registry,
                      {Antenna.Test.ID.Delivery, Antenna.Test.ID.Delivery.Broadcaster}},
                     {:notify, {[:timeout_channel], {:timeout_test, "should timeout"}}, 100, true},
                     200
                   ]}}
    end

    # The handler should still complete eventually, even though the sync_event timed out
    assert_receive {:timeout_handler_completed, :timeout_channel, {:timeout_test, "should timeout"}}, 1_000

    # Using a longer timeout should allow the handler to complete
    results_with_timeout = Antenna.sync_event(@antenna, :timeout_channel, {:timeout_test, "should complete"}, 1_000)

    # Verify we got a proper response
    assert [{:match, %{results: [{:ok, :handler_response}]}} | _] = results_with_timeout
    assert_receive {:timeout_handler_completed, :timeout_channel, {:timeout_test, "should complete"}}, 1_000

    # Clean up
    assert :ok = Antenna.unmatch(@antenna, {:timeout_test, _})
  end

  test "error handling in matchers" do
    test_pid = self()

    # Create a matcher with a handler that raises an exception
    assert {:ok, error_pid, "{:error_test, action: action} when action in [:ok, :error, :raise]"} =
             Antenna.match(
               @antenna,
               {:error_test, action: action} when action in [:ok, :error, :raise],
               fn channel, {:error_test, action: action} = event ->
                 case action do
                   :ok ->
                     send(test_pid, {:error_handler, :success, channel, event})
                     {:ok, :success}

                   :error ->
                     send(test_pid, {:error_handler, :error, channel, event})
                     {:error, :failed}

                   :raise ->
                     send(test_pid, {:error_handler, :before_raise, channel, event})
                     raise "Deliberate exception in handler"
                     # This line should never execute
                     send(test_pid, {:error_handler, :after_raise, channel, event})
                 end
               end,
               channels: [:error_channel]
             )

    assert is_pid(error_pid)

    # Test normal case
    assert :ok = Antenna.event(@antenna, :error_channel, {:error_test, action: :ok})
    assert_receive {:error_handler, :success, :error_channel, {:error_test, action: :ok}}, 1_000

    # Test error tuple return
    assert :ok = Antenna.event(@antenna, :error_channel, {:error_test, action: :error})
    assert_receive {:error_handler, :error, :error_channel, {:error_test, action: :error}}, 1_000

    # Test exception handling
    assert :ok = Antenna.event(@antenna, :error_channel, {:error_test, action: :raise})
    assert_receive {:error_handler, :before_raise, :error_channel, {:error_test, action: :raise}}, 1_000
    # Should never receive the after_raise message since the exception aborts the handler
    refute_receive {:error_handler, :after_raise, _, _}, 100

    # After raising an exception, the system should still function
    assert :ok = Antenna.event(@antenna, :error_channel, {:error_test, action: :ok})
    assert_receive {:error_handler, :success, :error_channel, {:error_test, action: :ok}}, 1_000

    # IO.inspect(
    #   Antenna.Guard.all(
    #     @antenna,
    #     Macro.to_string(quote do: {:error_test, action: action} when action in [:ok, :error, :raise])
    #   ),
    #   label: "★★★★★"
    # )

    # Test sync_event with different return types
    # Success case
    results_ok = Antenna.sync_event(@antenna, :error_channel, {:error_test, action: :ok})
    assert [{:match, %{results: [{:ok, :success}]}} | _] = results_ok
    assert_receive {:error_handler, :success, :error_channel, {:error_test, action: :ok}}, 1_000

    # Error tuple case
    results_error = Antenna.sync_event(@antenna, :error_channel, {:error_test, action: :error})
    assert [{:match, %{results: [{:error, :failed}]}} | _] = results_error
    assert_receive {:error_handler, :error, :error_channel, {:error_test, action: :error}}, 1_000

    # Exception case
    # The system should handle the exception and still return a result, though the handler result might be missing
    _results_exception = Antenna.sync_event(@antenna, :error_channel, {:error_test, action: :raise})
    assert_receive {:error_handler, :before_raise, :error_channel, {:error_test, action: :raise}}, 1_000
    refute_receive {:error_handler, :after_raise, _, _}, 100

    # The system should still function after an exception
    results_after_exception = Antenna.sync_event(@antenna, :error_channel, {:error_test, action: :ok})
    assert [{:match, %{results: [{:ok, :success}]}} | _] = results_after_exception
    assert_receive {:error_handler, :success, :error_channel, {:error_test, action: :ok}}, 1_000

    # Clean up
    assert :ok = Antenna.unmatch(@antenna, {:error_test, action: action} when action in [:ok, :error, :raise])
  end
end
