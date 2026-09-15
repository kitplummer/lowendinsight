defmodule Lei.Repo do
  # Owned by the service since ADR-003. Its migrations keep their versions under
  # priv/lei_repo -- set as `priv:` in config/config.exs, which is where Ecto
  # reads it; as an option here it is silently ignored.
  use Ecto.Repo,
    otp_app: :lowendinsight_get,
    adapter: Ecto.Adapters.Postgres
end
