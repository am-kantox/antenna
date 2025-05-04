defmodule Antenna.ExUnit do
  @moduledoc """
  The helper module for ExUnit tests. It exports `assert_event/2` and `refute_event/2` functions to assert and refute events.
  """

  @doc """
  Asserts that an event is received within the specified timeout.

  ## Example

  ```elixir
  assert_event(Antenna, {:foo, _}, :chan_1, _, fn -> provoke_foo(Fooer) end)
  ```
  """
  defmacro assert_event(id \\ nil, match, channels, event, timeout \\ 5000, fun) do
    quote generated: true, location: :keep do
      id = unquote(id) || Antenna.id()

      assert {name, pid} = Antenna.lookup(id, unquote(match))
      assert is_pid(pid)

      assert :ok = Antenna.handle(id, self(), pid)

      unquote(fun).()

      unquote(channels)
      |> List.wrap()
      |> Enum.each(fn channel ->
        assert_receive {:antenna_event, ^channel, unquote(event)}, unquote(timeout)
      end)

      assert :ok = Antenna.unhandle(id, self(), pid)
    end
  end
end
