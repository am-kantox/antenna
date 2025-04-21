global_settings = Path.expand("~/.iex.exs")
if File.exists?(global_settings), do: Code.eval_file(global_settings)

require Antenna
