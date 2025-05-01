defmodule Antenna.Enfiladex.Test do
  use ExUnit.Case, async: true

  use Enfiladex.Suite

  alias Antenna.Test.Matcher

  require Antenna

  setup do
    %{}
  end

  @tag :enfiladex
  test "start, stop", _ctx do
    count = 1
    peers = Enfiladex.start_peers(count)

    try do
      Enfiladex.block_call_everywhere(Antenna, :start_link, [Antenna])

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
    after
      Enfiladex.stop_peers(peers)
    end
  end
end
