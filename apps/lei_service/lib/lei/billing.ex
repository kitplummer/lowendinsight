defmodule Lei.Billing do
  @moduledoc """
  Whether this deployment charges for analysis.

      :charge   the rates in ADR-001 apply
      :beta     analysis is free, bounded by the free tier's allowance

  Beta exists to build the shared cache up, exercise the flows end to end and
  find out what scaling actually costs, none of which needs money to move. See
  ADR-007.

  ## Why a mode and not rates set to zero

  Setting `credits_per_cache_miss` to 0 would produce the same behaviour and
  would be indistinguishable from the bug where billing silently stops working.
  This repository has shipped "something reports success while broken" nine
  times; a deployment serving for free is exactly that shape, and the only
  difference between the intended version and the defect is that somebody meant
  it. A named mode can be published on /metrics, asserted by the monitor, and
  said out loud in the agent guide.

  ## Why the default is charging

  An unset value, a typo, a config file that failed to load: every one of those
  resolves to `:charge`. Getting free service wrong costs revenue silently and
  indefinitely, while getting charging wrong is reported by the customer within
  the hour. The failure that announces itself is the better default.
  """

  @modes [:charge, :beta]

  @doc """
  The billing mode in force. Anything unrecognised is `:charge`.
  """
  def mode do
    case Application.get_env(:lei_service, :billing_mode) do
      mode when mode in @modes -> mode
      _ -> :charge
    end
  end

  @doc "Whether analysis is free right now."
  def beta?, do: mode() == :beta

  @doc """
  The modes this understands, so a listing of them never drifts from the
  behaviour.
  """
  def modes, do: @modes
end
