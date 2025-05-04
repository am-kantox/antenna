import Config

config :logger, level: System.get_env("LOG_LEVEL", "debug") |> String.to_existing_atom()

if File.exists?("config/#{Mix.env()}.exs"), do: import_config("#{Mix.env()}.exs")
