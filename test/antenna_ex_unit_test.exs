defmodule Antenna.ExUnit.Test do
  use ExUnit.Case, async: true

  require Antenna
  require Antenna.ExUnit

  alias Antenna.Test.Matcher

  @antenna __MODULE__.ID

  setup_all ctx do
    Map.put(ctx, :antenna_pid, start_supervised!({Antenna, id: @antenna}))
  end

  @tag :ex_unit
  test "handle_event/5", _ctx do
    assert {:ok, _pid, "{:tag_ex_unit_1, _}"} =
             Antenna.match(@antenna, {:tag_ex_unit_1, _}, [Matcher], channels: [:chan_ex_unit_1])

    Antenna.ExUnit.assert_event(@antenna, {:tag_ex_unit_1, _}, [:chan_ex_unit_1], {:tag_ex_unit_1, 42}, 5000, fn ->
      assert :ok = Antenna.event(@antenna, [:chan_ex_unit_1], {:tag_ex_unit_1, 42})
    end)
  end
end
