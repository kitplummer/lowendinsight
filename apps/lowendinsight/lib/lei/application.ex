defmodule Lei.Application do
  @moduledoc """
  OTP application for the LowEndInsight library.

  Starts only what the analyzer itself needs: the ETS-backed batch cache. The
  hosted service's processes -- its database, rate limiter, payment and Stripe
  checks, and HTTP endpoint -- are started by `LeiService.Application`,
  so an application depending on this library gets an analyzer, not a service
  (ADR-003).
  """
  use Application

  @impl true
  def start(_type, _args) do
    Lei.AgenticDetector.warn_deprecated_env_vars()

    children = [Lei.BatchCache]

    Supervisor.start_link(children, strategy: :one_for_one, name: Lei.Supervisor)
  end
end
