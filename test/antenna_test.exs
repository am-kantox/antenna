defmodule AntennaTest do
  use ExUnit.Case, async: true
  doctest Antenna

  test "straight single node" do
    assert {:ok, pid1, "{:tag_1, a, _} when is_nil(a)"} =
             Antenna.match(Antenna, {:tag_1, a, _} when is_nil(a), self(), channels: [:chan_1])

    assert :ok = Antenna.event(Antenna, [:chan_1], {:tag_1, nil, 42})
    assert_receive {:antenna_event, :chan_1, {:tag_1, nil, 42}}

    assert %Antenna.Guard{groups: %{chan_1: pids}} = :sys.get_state(GenServer.whereis(Antenna.guard(Antenna)))
    assert 1 = MapSet.size(pids)

    assert {:ok, pid2, "{:tag_1, _}"} = Antenna.match(Antenna, {:tag_1, _}, self(), channels: [:chan_1])
    assert :ok = Antenna.event(Antenna, [:chan_1], {:tag_1, 42})
    assert_receive {:antenna_event, :chan_1, {:tag_1, 42}}

    assert %Antenna.Guard{groups: %{chan_1: pids}} = :sys.get_state(GenServer.whereis(Antenna.guard(Antenna)))
    assert ^pids = MapSet.new([pid1, pid2])
    assert :ok = Antenna.unmatch(Antenna, {:tag_1, a, _} when is_nil(a))

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
end
