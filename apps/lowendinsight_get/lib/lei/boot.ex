defmodule Lei.Boot do
  @moduledoc """
  Configuration that must be right before the service starts. Public so the
  refusals are testable without restarting the application.

  Was `Lei.Application.boot_checks!/0`, from when the library application
  started the service's processes (ADR-003).
  """

  def checks! do
    # Fail here rather than mid-payment. A rail whose name the ledger will not
    # accept can verify a real settlement and then fail to record it, leaving
    # money taken and nothing in an append-only ledger to find it by.
    :ok = Lei.Payments.validate_rails!()

    # A live key on a laptop, or a webhook secret in the key slot, is refused
    # here. Whether the prices match the key's mode needs Stripe, so that is
    # Lei.Stripe.ObjectCheck's job after boot, not a condition of booting.
    :ok = Lei.Stripe.Mode.validate!()
  end

  @doc "The service's own processes, started by LowendinsightGet.Application."
  def children do
    base = [
      Lei.Repo,
      Lei.RateLimiter,
      Lei.Payments.ChallengeReaper,
      Lei.Stripe.ObjectCheck
    ]

    if Application.get_env(:lowendinsight, :start_http, false) do
      port = Application.get_env(:lowendinsight, :http_port, 4000)
      base ++ [{Plug.Cowboy, scheme: :http, plug: Lei.Web.Router, options: [port: port]}]
    else
      base
    end
  end
end
