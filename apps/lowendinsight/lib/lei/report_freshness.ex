defmodule Lei.ReportFreshness do
  @moduledoc """
  Brings a stored report's time-dependent risk up to the present (#242).

  Five of the six risk metrics are pure functions of a cloned git history: they
  can only change when the upstream repository changes, so a stored value stays
  correct for as long as the entry describes the same commit.
  `commit_currency_risk` is the exception. It is derived from
  `DateTime.utc_now()` and is therefore correct only at the instant it was
  computed:

      weeks = TimeHelper.get_commit_delta(date) |> TimeHelper.sec_to_weeks()

  Stored as a number and served unchanged, it reports the risk a repository
  held when it was analysed rather than the risk it holds now -- so a project
  drifting into abandonment keeps the verdict it had before it went quiet. That
  is the one signal this analysis exists to raise, which made the cache a way
  of suppressing it.

  Nothing here re-analyses anything. `data.git.last_commit_date` is already
  stored beside the frozen week count, and the true figure is that date against
  the clock. No clone, no network, no new data -- only arithmetic that should
  have been done on the way out rather than on the way in.

  Operates on the string-keyed map a report decodes to from JSON.
  `AnalyzerModule.determine_toplevel_risk/1` is not reusable for the rollup: it
  reads atom keys, and it uses `Map.put_new/3`, so on a report that already
  carries a risk -- which every stored report does -- it silently keeps the old
  one.
  """

  @doc """
  Returns the report with its commit currency, and the risk rolled up from it,
  recomputed against the current time.

  A report that cannot be recomputed is returned exactly as it was given: no
  `data.git.last_commit_date`, a date that will not parse, or no results to
  revise. Those entries predate the field or came from somewhere that does not
  set it, and the alternative -- treating a missing date as zero elapsed weeks
  -- would publish a confident "low" derived from nothing, which is the same
  defect this function exists to remove.
  """
  @spec refresh(map) :: map
  def refresh(%{"data" => %{"results" => results}} = report) when is_map(results) do
    with date when is_binary(date) <- get_in(report, ["data", "git", "last_commit_date"]),
         seconds when is_integer(seconds) <- TimeHelper.get_commit_delta(date),
         weeks = TimeHelper.sec_to_weeks(seconds),
         {:ok, risk} <- RiskLogic.commit_currency_risk(weeks) do
      revised =
        results
        |> Map.put("commit_currency_weeks", weeks)
        |> Map.put("commit_currency_risk", risk)

      data =
        report
        |> Map.fetch!("data")
        |> Map.put("results", revised)
        |> Map.put("risk", toplevel_risk(revised))

      Map.put(report, "data", data)
    else
      _ -> report
    end
  end

  def refresh(report), do: report

  @doc """
  Decodes, refreshes and re-encodes a stored report.

  Anything that is not a decodable report is passed through untouched: a read
  returning what it found is a cache miss at worst, while raising here would
  turn one malformed entry into a failed request.
  """
  @spec refresh_json(binary) :: binary
  def refresh_json(json) when is_binary(json) do
    case Poison.decode(json) do
      {:ok, report} when is_map(report) -> report |> refresh() |> Poison.encode!()
      _ -> json
    end
  end

  def refresh_json(other), do: other

  # The report's verdict is the worst of its metrics. Recomputed across all of
  # them rather than compared against the stored verdict, so that a currency
  # that has improved cannot drag down a repository that is critical for some
  # entirely separate reason.
  defp toplevel_risk(results) do
    values = Map.values(results)

    cond do
      "critical" in values -> "critical"
      "high" in values -> "high"
      "medium" in values -> "medium"
      true -> "low"
    end
  end
end
