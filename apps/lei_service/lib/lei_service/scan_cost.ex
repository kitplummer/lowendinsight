defmodule LeiService.ScanCost do
  @moduledoc """
  What it would cost to analyse everything a real manifest depends on that we do
  not already hold.

  The arithmetic only. `mix lei.scan_cost` does the measuring and the printing.

  Quantities, not money, unless a rate card is supplied. The unit cost record of
  2026-09-20 deliberately did not multiply out host rates: the quantities are
  measured and durable, rate cards change, and a price baked in now would be
  wrong later and quoted anyway.
  """

  @doc """
  Per-repository cost from a measured sample.

  Takes `[%{seconds:, clone_bytes:, report_bytes:}]` for the repositories that
  analysed, and the count that failed. Failures are carried, not averaged away:
  a sample where half the clones failed has a flattering mean, and the whole
  point of costing is to not be surprised.
  """
  @spec per_repository([map()], non_neg_integer()) :: map()
  def per_repository(samples, failed) do
    %{
      sampled: length(samples),
      failed: failed,
      failure_rate: rate(failed, length(samples) + failed),
      seconds: stats(samples, :seconds),
      clone_bytes: stats(samples, :clone_bytes),
      report_bytes: stats(samples, :report_bytes)
    }
  end

  defp stats([], _key), do: %{median: nil, mean: nil, max: nil}

  defp stats(samples, key) do
    values = samples |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sort()

    %{median: median(values), mean: mean(values), max: List.last(values)}
  end

  defp median(values) do
    n = length(values)
    mid = div(n, 2)

    case rem(n, 2) do
      1 -> Enum.at(values, mid)
      0 -> (Enum.at(values, mid - 1) + Enum.at(values, mid)) / 2
    end
  end

  defp mean(values), do: Enum.sum(values) / length(values)

  # nil, not 0: "nothing was sampled" and "nothing failed" must not print alike.
  defp rate(_n, 0), do: nil
  defp rate(n, total), do: Float.round(n * 100 / total, 1)

  @doc """
  The whole corpus, from the per-repository sample.

  `opts`:
    * `:concurrency` - analyses in flight, for wall clock. Default 5.
    * `:churn` - the share of the corpus that changes in a month, as a fraction.
      Default 0.41, the midpoint of the 38-44% measured on 2026-09-20.
    * `:ttl_days` - cache TTL. Default from config, which is 30.

  Two monthly figures, because the difference between them is the argument for
  the watch model rather than a detail:

    * `naive_monthly` - the TTL expires everything, so everything is analysed
      again whether or not it changed.
    * `watched_monthly` - an ls-remote probe per repository, and analysis only
      for the share that moved.
  """
  @spec extrapolate(non_neg_integer(), map(), keyword()) :: map()
  def extrapolate(count, per_repo, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, 5)
    churn = Keyword.get(opts, :churn, 0.41)
    ttl_days = Keyword.get(opts, :ttl_days, 30)
    probe_seconds = Keyword.get(opts, :probe_seconds, 0.258)

    mean_seconds = per_repo.seconds.mean
    mean_clone = per_repo.clone_bytes.mean
    mean_report = per_repo.report_bytes.mean

    if is_nil(mean_seconds) do
      %{repositories: count, measurable: false}
    else
      one_pass = %{
        repositories: count,
        cpu_seconds: count * mean_seconds,
        wall_clock_seconds: count * mean_seconds / concurrency,
        ingress_bytes: round(count * mean_clone),
        stored_bytes: round(count * mean_report)
      }

      changed = round(count * churn)
      passes_per_month = 30 / ttl_days

      %{
        measurable: true,
        one_pass: one_pass,
        naive_monthly: %{
          analyses: round(count * passes_per_month),
          cpu_seconds: count * passes_per_month * mean_seconds,
          ingress_bytes: round(count * passes_per_month * mean_clone)
        },
        watched_monthly: %{
          probes: count * 30,
          probe_seconds: count * 30 * probe_seconds,
          analyses: changed,
          cpu_seconds: changed * mean_seconds,
          ingress_bytes: round(changed * mean_clone)
        },
        assumptions: %{
          concurrency: concurrency,
          churn: churn,
          ttl_days: ttl_days,
          probe_seconds: probe_seconds
        }
      }
    end
  end

  @doc """
  Quantities times a rate card.

  `rates` are USD: `cpu_hour`, `ingress_gb`, `storage_gb_month`. Any missing rate
  leaves its line out rather than treating it as free -- a zero would silently
  make a cost disappear, and the total would still look like a total.
  """
  @spec price(map(), map()) :: map()
  def price(quantities, rates) do
    lines =
      [
        {:cpu, rates["cpu_hour"], Map.get(quantities, :cpu_seconds, 0) / 3600},
        {:ingress, rates["ingress_gb"], Map.get(quantities, :ingress_bytes, 0) / 1_000_000_000},
        {:storage, rates["storage_gb_month"],
         Map.get(quantities, :stored_bytes, 0) / 1_000_000_000}
      ]
      |> Enum.reject(fn {_name, rate, _qty} -> is_nil(rate) end)
      |> Map.new(fn {name, rate, qty} -> {name, Float.round(rate * qty, 2)} end)

    missing =
      ["cpu_hour", "ingress_gb", "storage_gb_month"] |> Enum.reject(&Map.has_key?(rates, &1))

    %{
      usd: lines,
      total_usd: lines |> Map.values() |> Enum.sum() |> Float.round(2),
      missing: missing
    }
  end
end
