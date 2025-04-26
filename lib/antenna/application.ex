defmodule Antenna.Application do
  @moduledoc false

  use Elixir.Application

  @impl Elixir.Application
  def start(_type, args) do
    id = with true <- Keyword.keyword?(args), {:ok, id} <- Keyword.fetch(args, :id), do: id, else: (_ -> Antenna.id())
    Supervisor.start_link([{Antenna, id}], strategy: :one_for_one)
  end

  @impl Application
  def start_phase(:antenna_setup, _start_type, []), do: :ok
end
