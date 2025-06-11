defmodule Antenna.PubSubTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Test suite for the Antenna.PubSub functionality.
  """

  require Antenna

  @antenna __MODULE__.ID

  setup_all ctx do
    Map.put(ctx, :antenna_pid, start_supervised!({Antenna, id: @antenna}))
  end

  describe "basic pub/sub functionality" do
    test "handles single publisher, single subscriber" do
      assert {:ok, _pid, _} = Antenna.match(@antenna, {:test_event, _}, [self()], channels: [:test_channel])
      assert :ok = Antenna.event(@antenna, [:test_channel], {:test_event, "data"})

      assert_receive {:antenna_event, :test_channel, {:test_event, "data"}}, 1_000
    end

    test "handles multiple subscribers" do
      # Create two subscribers
      assert {:ok, pid, _} = Antenna.match(@antenna, {:multi_event, _}, [self()], channels: [:multi_channel])

      assert {:error, {:already_started, ^pid}} =
               Antenna.match(@antenna, {:multi_event, _}, [self()], channels: [:multi_channel])

      # Send event and verify both receive it
      assert :ok = Antenna.event(@antenna, [:multi_channel], {:multi_event, "data"})

      assert_receive {:antenna_event, :multi_channel, {:multi_event, "data"}}, 1_000
      refute_receive {:antenna_event, :multi_channel, {:multi_event, "data"}}
    end
  end

  describe "sync event handling" do
    test "collects responses from all handlers (no subsequent matches)" do
      # Register two handlers that return different transformations
      assert {:ok, pid, _} =
               Antenna.match(@antenna, {:sync_event, _}, fn _, {:sync_event, val} -> {:ok, String.upcase(val)} end,
                 channels: [:sync_channel]
               )

      assert {:error, {:already_started, ^pid}} =
               Antenna.match(
                 @antenna,
                 {:sync_event, _},
                 fn _, {:sync_event, val} -> {:ok, String.downcase(val)} end,
                 channels: [:sync_channel]
               )

      # Send sync event and verify responses
      results = Antenna.sync_event(@antenna, [:sync_channel], {:sync_event, "Test"})

      assert Enum.any?(results, fn
               {:match, %{results: [ok: "TEST"]}} -> true
               _ -> false
             end)

      refute Enum.any?(results, fn
               {:match, %{results: [{:ok, "test"}]}} -> true
               _ -> false
             end)
    end

    test "collects responses from all handlers (subsequent matches)" do
      # Register two handlers that return different transformations
      assert {:ok, pid, _} =
               Antenna.match(
                 @antenna,
                 {:sync_event_sm, _},
                 fn _, {:sync_event_sm, val} -> {:ok, String.upcase(val)} end,
                 channels: [:sync_channel_sm],
                 subsequent_matches?: true
               )

      assert {:error, {:already_started, ^pid}} =
               Antenna.match(
                 @antenna,
                 {:sync_event_sm, _},
                 fn _, {:sync_event_sm, val} -> {:ok, String.downcase(val)} end,
                 channels: [:sync_channel_sm],
                 subsequent_matches?: true
               )

      # Send sync event and verify responses
      results = Antenna.sync_event(@antenna, [:sync_channel_sm], {:sync_event_sm, "Test"})

      assert Enum.any?(results, fn
               {:match, %{results: results}} -> assert [ok: "TEST", ok: "test"] == Enum.sort(results)
               _ -> false
             end)
    end

    test "handles timeouts properly" do
      # Register a slow handler
      assert {:ok, _pid, _} =
               Antenna.match(
                 @antenna,
                 {:slow_event, _},
                 fn _, _ ->
                   Process.sleep(1000)
                   :ok
                 end,
                 channels: [:timeout_channel]
               )

      # Send sync event with short timeout
      results =
        try do
          Antenna.sync_event!(@antenna, [:timeout_channel], {:slow_event, "data"}, 100)
        catch
          :exit, {:timeout, _} -> []
        end

      # Should get empty results due to timeout
      assert [] = results

      results = Antenna.sync_event(@antenna, [:timeout_channel], {:slow_event, "data"}, 100)

      # Should get empty results due to timeout
      assert [error: _] = results
    end
  end

  describe "error handling" do
    test "survives handler crashes" do
      # Register a crashing handler
      assert {:ok, _pid, _} =
               Antenna.match(@antenna, {:crash_event, _}, fn _, _ -> raise "crash" end, channels: [:crash_channel])

      # Send event - should not crash the system
      assert :ok = Antenna.event(@antenna, [:crash_channel], {:crash_event, "data"})

      # System should still work
      assert {:ok, _pid2, _} = Antenna.match(@antenna, {:normal_event, _}, [self()], channels: [:crash_channel])
      assert :ok = Antenna.event(@antenna, [:crash_channel], {:normal_event, "data"})

      assert_receive {:antenna_event, :crash_channel, {:normal_event, "data"}}, 1_000
    end
  end
end
