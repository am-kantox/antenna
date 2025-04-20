import Config

config :logger, level: System.get_env("LOG_LEVEL", "debug") |> String.to_existing_atom()
