defmodule Antenna.Test.Matcher do
  @moduledoc false
  @behaviour Antenna.Matcher

  require Logger

  @impl Antenna.Matcher
  def handle_match(channel, event) do
    [channel: channel, event: event]
    |> inspect()
    |> Logger.notice()
  end
end
