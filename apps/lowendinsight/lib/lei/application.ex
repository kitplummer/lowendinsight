defmodule Lei.Application do
  @moduledoc """
  OTP Application for LEI batch analysis service.

  Starts the ETS-backed batch cache and optional HTTP endpoint.
  """
  use Application

  @impl true
  def start(_type, _args) do
    Lei.AgenticDetector.warn_deprecated_env_vars()

    # Fail here rather than mid-payment. A rail whose name the ledger will not
    # accept can verify a real settlement and then fail to record it, leaving
    # money taken and nothing in an append-only ledger to find it by.
    :ok = Lei.Payments.validate_rails!()

    port = Application.get_env(:lowendinsight, :http_port, 4000)

    base = [Lei.Repo, Lei.BatchCache, Lei.RateLimiter]

    children =
      if Application.get_env(:lowendinsight, :start_http, false) do
        base ++ [{Plug.Cowboy, scheme: :http, plug: Lei.Web.Router, options: [port: port]}]
      else
        base
      end

    opts = [strategy: :one_for_one, name: Lei.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
