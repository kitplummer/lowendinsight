defmodule Lei.Repo do
  use Ecto.Repo,
    otp_app: :lowendinsight,
    adapter: Ecto.Adapters.SQLite3
end
