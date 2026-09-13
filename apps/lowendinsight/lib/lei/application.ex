defmodule Lei.Application do
  @moduledoc """
  OTP Application for LEI batch analysis service.

  Starts the ETS-backed batch cache and optional HTTP endpoint.
  """
  use Application

  @impl true
  def start(_type, _args) do
    Lei.AgenticDetector.warn_deprecated_env_vars()

    :ok = boot_checks!()

    port = Application.get_env(:lowendinsight, :http_port, 4000)

    base = [
      Lei.Repo,
      Lei.BatchCache,
      Lei.RateLimiter,
      Lei.Payments.ChallengeReaper,
      Lei.Stripe.ObjectCheck
    ]

    children =
      if Application.get_env(:lowendinsight, :start_http, false) do
        base ++ [{Plug.Cowboy, scheme: :http, plug: Lei.Web.Router, options: [port: port]}]
      else
        base
      end

    opts = [strategy: :one_for_one, name: Lei.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Configuration that must be right before anything starts. Public so the
  refusals are testable without restarting the application.
  """
  def boot_checks! do
    # Fail here rather than mid-payment. A rail whose name the ledger will not
    # accept can verify a real settlement and then fail to record it, leaving
    # money taken and nothing in an append-only ledger to find it by.
    :ok = Lei.Payments.validate_rails!()

    # A live key on a laptop, or a webhook secret in the key slot, is refused
    # here. Whether the prices match the key's mode needs Stripe, so that is
    # Lei.Stripe.ObjectCheck's job after boot, not a condition of booting.
    :ok = Lei.Stripe.Mode.validate!()
  end
end
