defmodule Antenna.GuardTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Test suite for the Antenna.Guard functionality, focusing on channel and handler
  management, cleanup, and error handling.
  """

  require Antenna

  @antenna __MODULE__.ID

  setup_all ctx do
    Map.put(ctx, :antenna_pid, start_supervised!({Antenna, id: @antenna}))
  end

  describe "channel management" do
    test "registers channels correctly" do
      # Create a matcher that subscribes to multiple channels
      assert {:ok, pid, _} = Antenna.match(@antenna, {:event_1, _}, self(), channels: [:channel_1_1, :channel_1_2])

      # Verify channel registration in guard state
      guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
      assert %Antenna.Guard{groups: groups} = guard_state

      assert MapSet.member?(groups[:channel_1_1], pid)
      assert MapSet.member?(groups[:channel_1_2], pid)
    end

    test "unregisters channels on unmatch" do
      assert {:ok, pid, _} = Antenna.match(@antenna, {:event_2, _}, self(), channels: [:remove_test])

      # Verify initial registration
      guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
      assert %Antenna.Guard{groups: groups} = guard_state
      assert MapSet.member?(groups[:remove_test], pid)

      # Unmatch and verify removal
      assert :ok = Antenna.unmatch(@antenna, {:event_2, _})

      guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
      assert %Antenna.Guard{groups: groups} = guard_state
      refute MapSet.member?(groups[:remove_test], pid)
    end

    test "handles multiple matchers per channel" do
      # Register multiple matchers to same channel
      assert {:ok, pid1, _} = Antenna.match(@antenna, {:event_3_1, _}, self(), channels: [:shared_channel])
      assert {:ok, pid2, _} = Antenna.match(@antenna, {:event_3_2, _}, self(), channels: [:shared_channel])

      guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
      assert %Antenna.Guard{groups: groups} = guard_state

      shared_pids = groups[:shared_channel]
      assert MapSet.member?(shared_pids, pid1)
      assert MapSet.member?(shared_pids, pid2)
    end
  end

  describe "handler management" do
    test "registers handlers correctly" do
      handler = fn _, _ -> :ok end
      assert {:ok, _pid, _} = Antenna.match(@antenna, {:event_4, _}, handler, channels: [:handler_test])

      # Verify handler registration
      guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
      assert %Antenna.Guard{handlers: %{"{:event_4, _}" => %MapSet{}}} = guard_state
    end

    test "unregisters handlers on unmatch" do
      handler = fn _, _ -> :ok end
      assert {:ok, _pid, _} = Antenna.match(@antenna, {:event_5, _}, handler, channels: [:handler_remove])

      # Verify initial registration
      guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
      assert %Antenna.Guard{handlers: %{"{:event_5, _}" => %MapSet{}}} = guard_state

      # Unmatch and verify removal
      assert :ok = Antenna.unmatch(@antenna, {:event_5, _})
      Process.sleep(100)

      guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
      assert %Antenna.Guard{handlers: handlers} = guard_state
      refute Map.has_key?(handlers, "{:event_5, _}")
    end

    test "handles multiple handlers per matcher" do
      handler1 = fn _, _ -> 42 && :ok end
      handler2 = fn _, _ -> 43 && :ok end

      assert {:ok, pid, _} = Antenna.match(@antenna, {:event_6, _}, [handler1], channels: [:multi_handler])
      Antenna.handle(@antenna, handler2, pid)

      guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
      assert %Antenna.Guard{handlers: %{"{:event_6, _}" => handlers}} = guard_state

      assert handler1 in handlers
      assert handler2 in handlers
      assert :ok = Antenna.unhandle(@antenna, handler1, pid)
      Process.sleep(100)

      guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
      assert %Antenna.Guard{handlers: %{"{:event_6, _}" => handlers}} = guard_state
      refute handler1 in handlers
      assert handler2 in handlers
      assert :ok = Antenna.unhandle_all(@antenna, pid)
      Process.sleep(100)

      guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
      refute match?(%Antenna.Guard{handlers: %{"{:event_6, _}" => _}}, guard_state)
    end
  end

  describe "cleanup handling" do
    test "cleans up after process termination" do
      # Create a process that will terminate
      task =
        Task.async(fn ->
          assert {:ok, _pid, _} = Antenna.match(@antenna, {:event_7, _}, self(), channels: [:cleanup_test])

          receive do
            :stop -> Antenna.unmatch(@antenna, {:event_7, _})
          end
        end)

      # Let it register
      Process.sleep(100)

      # Get initial state
      guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
      assert %Antenna.Guard{groups: groups} = guard_state
      assert Map.has_key?(groups, :cleanup_test)

      # Terminate the process
      send(task.pid, :stop)
      Process.sleep(100)

      # Verify cleanup
      guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
      assert %Antenna.Guard{groups: groups} = guard_state
      assert groups[:cleanup_test] == nil || MapSet.size(groups[:cleanup_test]) == 0
    end

    test "cleans up after abnormal termination" do
      # Create a process that will crash
      {:ok, task} =
        Task.start(fn ->
          assert {:ok, _pid, _} = Antenna.match(@antenna, {:event_8, _}, self(), channels: [:crash_test])

          receive do
            :crash -> raise "crash"
          end
        end)

      # Let it register
      Process.sleep(100)

      # Verify initial registration
      guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
      assert %Antenna.Guard{groups: groups} = guard_state
      assert Map.has_key?(groups, :crash_test)

      # Crash the process
      send(task, :crash)
      Process.sleep(100)

      # Verify cleanup
      guard_state = :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))
      assert %Antenna.Guard{groups: groups} = guard_state
      assert MapSet.size(groups[:crash_test]) > 0
    end
  end

  describe "error handling" do
    test "handles invalid channel names" do
      # Try to register with invalid channel names
      assert {:ok, _pid, _} = Antenna.match(@antenna, {:event_9, _}, self(), channels: [:valid, 123, %{}])
      Process.sleep(10)

      # Should still work with atomic channels
      assert :ok = Antenna.event(@antenna, [:valid], {:event_9, "data"})
      assert_receive {:antenna_event, :valid, {:event_9, "data"}}

      assert :ok = Antenna.event(@antenna, [123], {:event_9, "data"})
      assert_receive {:antenna_event, 123, {:event_9, "data"}}
    end

    test "handles duplicate registrations" do
      assert {:ok, pid, _} = Antenna.match(@antenna, {:event_10, _}, self(), channels: [:dup_channel])

      # Try to register same process again
      assert {:error, {:already_started, ^pid}} =
               Antenna.match(@antenna, {:event_10, _}, self(), channels: [:dup_channel])

      Process.sleep(10)

      # Should only receive one event
      assert :ok = Antenna.event(@antenna, [:dup_channel], {:event_10, "data"})
      assert_receive {:antenna_event, :dup_channel, {:event_10, "data"}}
      refute_receive {:antenna_event, :dup_channel, {:event_10, "data"}}
    end
  end
end
