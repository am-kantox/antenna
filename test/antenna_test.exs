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
    Process.sleep(100)

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
    assert_receive {:antenna_event, :chan_2, {:tag_2, 42}}
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
    Process.sleep(100)

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
end
