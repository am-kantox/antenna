defmodule Antenna.Test do
  use ExUnit.Case, async: true
  doctest Antenna

  alias Antenna.Test.Matcher

  setup_all ctx do
    Map.put(ctx, :antenna_pid, start_supervised!(Antenna))
  end

  test "straight single node (async)" do
    assert {:ok, pid1, "{:tag_1, a, _} when is_nil(a)"} =
             Antenna.match(Antenna, {:tag_1, a, _} when is_nil(a), self(), channels: [:chan_1])

    assert :ok = Antenna.event(Antenna, [:chan_1], {:tag_1, nil, 42})
    assert_receive {:antenna_event, :chan_1, {:tag_1, nil, 42}}

    assert %Antenna.Guard{groups: %{chan_1: pids}} = :sys.get_state(GenServer.whereis(Antenna.guard(Antenna)))
    assert 1 = MapSet.size(pids)

    assert {:ok, pid2, "{:tag_1, _}"} = Antenna.match(Antenna, {:tag_1, _}, [Matcher, self()], channels: [:chan_1])
    assert :ok = Antenna.event(Antenna, [:chan_1], {:tag_1, 42})
    assert_receive {:antenna_event, :chan_1, {:tag_1, 42}}

    assert %{"{:tag_1, a, _} when is_nil(a)" => {^pid1, _}, "{:tag_1, _}" => {^pid2, _}} =
             Antenna.registered_matchers(Antenna)

    assert %Antenna.Guard{groups: %{chan_1: pids}} = :sys.get_state(GenServer.whereis(Antenna.guard(Antenna)))
    assert ^pids = MapSet.new([pid1, pid2])
    assert :ok = Antenna.unmatch(Antenna, {:tag_1, a, _} when is_nil(a))
    Process.sleep(100)

    assert :ok = Antenna.event(Antenna, [:chan_1], {:tag_1, 42})
    assert_receive {:antenna_event, :chan_1, {:tag_1, 42}}
    assert :ok = Antenna.event(Antenna, [:chan_1], {:tag_1, :chan_1, 42})
    refute_receive {:antenna_event, _, _}

    assert %Antenna.Guard{groups: %{chan_1: pids}} = :sys.get_state(GenServer.whereis(Antenna.guard(Antenna)))
    assert ^pids = MapSet.new([pid2])
  end

  test "once?: true" do
    assert {:ok, pid1, "{:tag_2, _}"} = Antenna.match(Antenna, {:tag_2, _}, self(), channels: [:chan_2], once?: true)

    assert %{"{:tag_2, _}" => {^pid1, %{id: Antenna.Matcher}}} =
             DistributedSupervisor.children(Antenna.matchers(Antenna))

    assert :ok = Antenna.event(Antenna, :chan_2, {:tag_2, 42})
    assert_receive {:antenna_event, :chan_2, {:tag_2, 42}}
    Process.sleep(100)

    refute Map.has_key?(DistributedSupervisor.children(Antenna.matchers(Antenna)), "{:tag_2, _}")
  end

  test "straight single node (sync)" do
    assert {:ok, pid1, "{:tag_3, a, _} when is_nil(a)"} =
             Antenna.match(Antenna, {:tag_3, a, _} when is_nil(a), self(), channels: [:chan_3])

    assert [
             match: %{
               match: "{:tag_3, a, _} when is_nil(a)",
               pid: ^pid1,
               channel: :chan_3,
               results: [{:antenna_event, :chan_3, {:tag_3, nil, 42}}]
             }
           ] = Antenna.sync_event(Antenna, [:chan_3], {:tag_3, nil, 42})

    assert_receive {:antenna_event, :chan_3, {:tag_3, nil, 42}}

    assert %Antenna.Guard{groups: %{chan_3: pids}} = :sys.get_state(GenServer.whereis(Antenna.guard(Antenna)))
    assert 1 = MapSet.size(pids)

    assert {:ok, pid2, "{:tag_3, _}"} = Antenna.match(Antenna, {:tag_3, _}, self(), channels: [:chan_3])

    assert [
             {:no_match, :chan_3},
             {:match, %{match: "{:tag_3, _}", channel: :chan_3, results: [{:antenna_event, :chan_3, {:tag_3, 42}}]}}
           ] = Antenna.sync_event(Antenna, [:chan_3], {:tag_3, 42})

    assert_receive {:antenna_event, :chan_3, {:tag_3, 42}}

    assert %Antenna.Guard{groups: %{chan_3: pids}} = :sys.get_state(GenServer.whereis(Antenna.guard(Antenna)))
    assert ^pids = MapSet.new([pid1, pid2])
    assert :ok = Antenna.unmatch(Antenna, {:tag_3, a, _} when is_nil(a))
    Process.sleep(100)

    assert [
             match: %{
               match: "{:tag_3, _}",
               pid: ^pid2,
               channel: :chan_3,
               results: [{:antenna_event, :chan_3, {:tag_3, 42}}]
             }
           ] = Antenna.sync_event(Antenna, [:chan_3], {:tag_3, 42})

    assert_receive {:antenna_event, :chan_3, {:tag_3, 42}}
    assert [{:no_match, :chan_3}] = Antenna.sync_event(Antenna, [:chan_3], {:tag_3, :chan_3, 42})
    refute_receive {:antenna_event, _, _}

    assert %Antenna.Guard{groups: %{chan_3: pids}} = :sys.get_state(GenServer.whereis(Antenna.guard(Antenna)))
    assert ^pids = MapSet.new([pid2])
  end
end
