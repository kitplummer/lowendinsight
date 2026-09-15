defmodule LeiService.Repo do
  use Ecto.Repo, otp_app: :lei_service, adapter: Ecto.Adapters.Postgres
end
