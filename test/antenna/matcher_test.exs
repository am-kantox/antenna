defmodule Antenna.MatcherTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Test suite for the Antenna.Matcher functionality.
  """

  require Antenna

  @antenna __MODULE__.ID

  setup_all ctx do
    Map.put(ctx, :antenna_pid, start_supervised!({Antenna, id: @antenna}))
  end

  describe "basic pattern matching" do
    test "matches exact patterns" do
      assert {:ok, _pid, _} = Antenna.match(@antenna, {:exact, 42}, [self()], channels: [:exact])

      # Should match exact value
      assert :ok = Antenna.event(@antenna, [:exact], {:exact, 42})
      assert_receive {:antenna_event, :exact, {:exact, 42}}

      # Should not match different value
      assert :ok = Antenna.event(@antenna, [:exact], {:exact, 43})
      refute_receive {:antenna_event, :exact, {:exact, 43}}
    end

    test "matches wildcards" do
      assert {:ok, _pid, _} = Antenna.match(@antenna, {:wild, _}, [self()], channels: [:wild])

      # Should match any second element
      assert :ok = Antenna.event(@antenna, [:wild], {:wild, 1})
      assert_receive {:antenna_event, :wild, {:wild, 1}}

      assert :ok = Antenna.event(@antenna, [:wild], {:wild, "string"})
      assert_receive {:antenna_event, :wild, {:wild, "string"}}
    end

    test "matches with pin operator" do
      assert {:ok, _pid, _} = Antenna.match(@antenna, {:pin, 42}, [self()], channels: [:pin])

      # Should match pinned value
      assert :ok = Antenna.event(@antenna, [:pin], {:pin, 42})
      assert_receive {:antenna_event, :pin, {:pin, 42}}

      # Should not match different value
      assert :ok = Antenna.event(@antenna, [:pin], {:pin, 43})
      refute_receive {:antenna_event, :pin, {:pin, 43}}
    end
  end

  describe "guard clauses" do
    test "matches with simple guards" do
      assert {:ok, _pid, _} =
               Antenna.match(
                 @antenna,
                 {:number, n} when n > 100,
                 [self()],
                 channels: [:guards]
               )

      # Should match numbers > 100
      assert :ok = Antenna.event(@antenna, [:guards], {:number, 150})
      assert_receive {:antenna_event, :guards, {:number, 150}}, 1_000

      # Should not match numbers <= 100
      assert :ok = Antenna.event(@antenna, [:guards], {:number, 50})
      refute_receive {:antenna_event, :guards, {:number, 50}}, 1_000
    end

    test "matches with complex guards" do
      assert {:ok, _pid, _} =
               Antenna.match(
                 @antenna,
                 {:complex, x, y} when is_integer(x) and x > 0 and is_binary(y),
                 [self()],
                 channels: [:complex]
               )

      # Should match valid inputs
      assert :ok = Antenna.event(@antenna, [:complex], {:complex, 1, "test"})
      assert_receive {:antenna_event, :complex, {:complex, 1, "test"}}

      # Should not match invalid inputs
      assert :ok = Antenna.event(@antenna, [:complex], {:complex, -1, "test"})
      refute_receive {:antenna_event, :complex, {:complex, -1, "test"}}

      assert :ok = Antenna.event(@antenna, [:complex], {:complex, 1, :not_binary})
      refute_receive {:antenna_event, :complex, {:complex, 1, :not_binary}}
    end
  end

  describe "map patterns" do
    test "matches map patterns" do
      assert {:ok, _pid, _} =
               Antenna.match(
                 @antenna,
                 %{type: :user, data: %{age: age}} when age >= 18,
                 [self()],
                 channels: [:maps]
               )

      # Should match valid maps
      assert :ok = Antenna.event(@antenna, [:maps], %{type: :user, data: %{age: 25}})
      assert_receive {:antenna_event, :maps, %{type: :user, data: %{age: 25}}}

      # Should not match invalid maps
      assert :ok = Antenna.event(@antenna, [:maps], %{type: :user, data: %{age: 15}})
      refute_receive {:antenna_event, :maps, %{type: :user, data: %{age: 15}}}

      assert :ok = Antenna.event(@antenna, [:maps], %{type: :other, data: %{age: 25}})
      refute_receive {:antenna_event, :maps, %{type: :other, data: %{age: 25}}}
    end
  end

  describe "one-time matchers" do
    test "are removed after first match" do
      assert {:ok, pid, _} =
               Antenna.match(
                 @antenna,
                 {:once, _},
                 [self()],
                 channels: [:once],
                 once?: true
               )

      # First event should be received
      assert :ok = Antenna.event(@antenna, [:once], {:once, 1})
      assert_receive {:antenna_event, :once, {:once, 1}}, 1_000

      # Wait for matcher to be removed
      Process.sleep(100)
      refute Process.alive?(pid)

      # Second event should not be received
      assert :ok = Antenna.event(@antenna, [:once], {:once, 2})
      refute_receive {:antenna_event, :once, {:once, 2}}
    end
  end
end
