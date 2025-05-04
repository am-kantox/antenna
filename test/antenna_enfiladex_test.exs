defmodule Antenna.Enfiladex.Test do
  use ExUnit.Case, async: true

  use Enfiladex.Suite

  alias Antenna.Test.Matcher

  require Antenna

  @antenna __MODULE__.ID

  setup_all ctx do
    Map.put(ctx, :antenna_pid, start_supervised!({Antenna, id: @antenna}))
  end

  @tag :enfiladex
  test "start, stop", _ctx do
    count = 1
    peers = Enfiladex.start_peers(count)

    try do
      Enfiladex.block_call_everywhere(Antenna, :start_link, [[id: @antenna]])

      assert {:ok, pid1, "{:tag_enfiladex_1, a, _} when is_nil(a)"} =
               Antenna.match(@antenna, {:tag_enfiladex_1, a, _} when is_nil(a), self(), channels: [:chan_enfiladex_1])

      assert :ok = Antenna.event(@antenna, [:chan_enfiladex_1], {:tag_enfiladex_1, nil, 42})
      assert_receive {:antenna_event, :chan_enfiladex_1, {:tag_enfiladex_1, nil, 42}}

      assert %Antenna.Guard{groups: %{chan_enfiladex_1: pids}} =
               :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))

      assert 1 = MapSet.size(pids)

      assert {:ok, pid2, "{:tag_enfiladex_1, _}"} =
               Antenna.match(@antenna, {:tag_enfiladex_1, _}, [Matcher, self()], channels: [:chan_enfiladex_1])

      Process.sleep(100)

      assert :ok = Antenna.event(@antenna, [:chan_enfiladex_1], {:tag_enfiladex_1, 42})
      assert_receive {:antenna_event, :chan_enfiladex_1, {:tag_enfiladex_1, 42}}

      assert %{"{:tag_enfiladex_1, a, _} when is_nil(a)" => {^pid1, _}, "{:tag_enfiladex_1, _}" => {^pid2, _}} =
               Antenna.registered_matchers(@antenna)

      assert %Antenna.Guard{groups: %{chan_enfiladex_1: pids}} =
               :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))

      assert ^pids = MapSet.new([pid1, pid2])
      assert :ok = Antenna.unmatch(@antenna, {:tag_enfiladex_1, a, _} when is_nil(a))
      Process.sleep(100)

      assert :ok = Antenna.event(@antenna, [:chan_enfiladex_1], {:tag_enfiladex_1, 42})
      assert_receive {:antenna_event, :chan_enfiladex_1, {:tag_enfiladex_1, 42}}
      assert :ok = Antenna.event(@antenna, [:chan_enfiladex_1], {:tag_enfiladex_1, :chan_enfiladex_1, 42})
      refute_receive {:antenna_event, _, _}

      assert %Antenna.Guard{groups: %{chan_enfiladex_1: pids}} =
               :sys.get_state(GenServer.whereis(Antenna.guard(@antenna)))

      assert ^pids = MapSet.new([pid2])
    after
      Enfiladex.stop_peers(peers)
    end
  end
end
