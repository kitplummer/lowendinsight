defmodule Mix.Tasks.Lei.ScanCost do
  @shortdoc "What it would cost to analyse everything a manifest depends on"

  @moduledoc """
  Cost the miss list that `mix lei.cache_baseline` produced.

      mix lei.scan_cost --baseline baseline.json --sample 25

  The baseline says how many repositories a real manifest depends on that we do
  not hold. This measures what one of them costs -- clone bytes, seconds, stored
  report -- on a random sample **of that list**, and multiplies.

  The sample has to come from the miss list itself. The unit cost record of
  2026-09-20 measured fifteen repositories chosen by hand, and its own finding
  was that history size drives the clone rather than project size: `jason` and
  `poison` each clone ~18 MB for a small report. So a mean taken from a different
  population is a mean for a different corpus. The transitive tail of an npm
  manifest is not fifteen hand-picked Elixir libraries.

  ## What it prints

  One pass over the miss list, then two monthly figures, because the gap between
  them is the whole argument for the watch model:

    * **naive** -- the 30-day TTL expires everything, so everything is analysed
      again whether or not it changed.
    * **watched** -- an `ls-remote` per repository per day, and analysis only for
      the share that moved.

  Quantities by default. `--rates` turns them into money; the file belongs in the
  ops repository, not this one.

  ## Options

    * `--baseline PATH` - the JSON from `mix lei.cache_baseline`. Required.
    * `--sample N` - repositories to measure. Default 25. Refused below
      `--min-sample`.
    * `--min-sample N` - default 10. A mean from three repositories is a guess
      with decimal places.
    * `--max-failures PCT` - default 20. Above this the sample is not costed:
      failed clones do not appear in the mean, so a broken sample reads cheap.
    * `--concurrency N` - analyses in flight, for the wall-clock figure only.
      Default 5. This does not run them concurrently; measuring one at a time is
      what makes the per-repository number meaningful.
    * `--churn F` - monthly share of the corpus that changes. Default 0.41.
    * `--rates PATH` - JSON with `cpu_hour`, `ingress_gb`, `storage_gb_month` in
      USD. Missing rates leave their line out rather than counting as free.
    * `--out PATH` - write the run as JSON.
    * `--seed N` - sampling seed, so a run is repeatable.

  ## It does not warm the cache it is costing

  Checked rather than assumed: after a twelve-repository run on 2026-09-28, none
  of the twelve were in Redis. This calls `AnalyzerModule.analyze` directly, and
  only the service writes reports to the cache. So the sample can be as large as
  patience allows without moving the next baseline's hit rate -- which would
  otherwise be a measurement quietly improving the thing it measures.
  """

  use Mix.Task

  alias LeiService.ScanCost

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          baseline: :string,
          sample: :integer,
          min_sample: :integer,
          max_failures: :float,
          concurrency: :integer,
          churn: :float,
          rates: :string,
          out: :string,
          seed: :integer
        ]
      )

    path = opts[:baseline] || Mix.raise("--baseline is required")
    wanted = opts[:sample] || 25
    min_sample = opts[:min_sample] || 10
    max_failures = opts[:max_failures] || 20.0

    baseline = path |> File.read!() |> Jason.decode!()

    missing =
      case baseline["repositories_missing"] do
        [_ | _] = urls ->
          urls

        _ ->
          Mix.raise(
            "#{path} has no repositories_missing. Re-run mix lei.cache_baseline: " <>
              "a count cannot be sampled, and costing a list we do not have is guessing."
          )
      end

    # Clones and analyses; writes nothing to Redis and reads nothing from it.
    LeiService.CacheBaseline.boot(:http)

    :rand.seed(:exsss, {opts[:seed] || 42, 0, 0})
    sample = missing |> Enum.shuffle() |> Enum.take(wanted)

    shell().info("""
    #{length(missing)} repositories in the miss list.
    Measuring #{length(sample)} of them, one at a time. Nothing is written to the
    cache, so the next baseline's hit rate is unaffected.
    """)

    measured = Enum.map(sample, &measure/1)
    {ok, failed} = Enum.split_with(measured, &match?({:ok, _}, &1))
    samples = Enum.map(ok, fn {:ok, s} -> s end)

    Enum.each(failed, fn {:error, url, reason} ->
      shell().error("  #{url}: #{inspect(reason)}")
    end)

    per_repo = ScanCost.per_repository(samples, length(failed))

    if length(samples) < min_sample do
      Mix.raise(
        "#{length(samples)} repositories analysed, needed at least #{min_sample}. " <>
          "Not extrapolating a corpus cost from that."
      )
    end

    if per_repo.failure_rate && per_repo.failure_rate > max_failures do
      Mix.raise(
        "#{per_repo.failed} of #{length(sample)} failed (#{per_repo.failure_rate}%), over the " <>
          "#{max_failures}% limit. A failed clone contributes nothing to the mean, so the cost " <>
          "below would read cheaper than the truth."
      )
    end

    estimate =
      ScanCost.extrapolate(length(missing), per_repo,
        concurrency: opts[:concurrency] || 5,
        churn: opts[:churn] || 0.41,
        ttl_days: div(LeiService.Datastore.cache_ttl_seconds(), 86_400)
      )

    rates = if p = opts[:rates], do: p |> File.read!() |> Jason.decode!()

    report(baseline, per_repo, estimate, rates, sample)

    if out = opts[:out] do
      File.write!(
        out,
        Jason.encode_to_iodata!(
          %{
            costed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            baseline_measured_at: baseline["measured_at"],
            sample: sample,
            per_repository: per_repo,
            estimate: estimate
          },
          pretty: true
        )
      )

      shell().info("\nWrote #{out}")
    end
  end

  defp shell, do: Mix.shell()

  # Cloned and analysed as two steps so the clone footprint can be measured
  # without cloning twice. Timed separately because they answer different
  # questions: the clone is ingress and mostly network, the analysis is CPU.
  defp measure(url) do
    {:ok, tmp} = Temp.mkdir(%{prefix: "scancost"})

    try do
      clone_started = System.monotonic_time(:millisecond)

      case GitModule.clone_repo(url, tmp) do
        {:ok, repo} ->
          clone_ms = System.monotonic_time(:millisecond) - clone_started
          clone_bytes = directory_bytes(tmp)

          analysis_started = System.monotonic_time(:millisecond)
          {:ok, report} = AnalyzerModule.analyze("file://" <> repo.path, "scan_cost", %{})
          analysis_ms = System.monotonic_time(:millisecond) - analysis_started

          {:ok,
           %{
             url: url,
             seconds: (clone_ms + analysis_ms) / 1000,
             clone_seconds: clone_ms / 1000,
             analysis_seconds: analysis_ms / 1000,
             clone_bytes: clone_bytes,
             report_bytes: byte_size(Jason.encode!(report))
           }}

        {:error, reason} ->
          {:error, url, reason}
      end
    rescue
      error -> {:error, url, Exception.message(error)}
    after
      File.rm_rf(tmp)
    end
  end

  # du, not a walk in Elixir: a repository's .git holds tens of thousands of
  # objects and the walk is slower than the clone it is measuring.
  defp directory_bytes(path) do
    case System.cmd("du", ["-sb", path], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split() |> hd() |> String.to_integer()
      _ -> 0
    end
  end

  defp report(baseline, per_repo, estimate, rates, sample) do
    shell().info("""

    Per repository, from #{per_repo.sampled} sampled (#{per_repo.failed} failed)
                        median      mean       max
      seconds        #{col(per_repo.seconds)}
      clone          #{col(per_repo.clone_bytes, :mb)}
      report         #{col(per_repo.report_bytes, :kb)}
    """)

    if estimate.measurable do
      one = estimate.one_pass
      a = estimate.assumptions

      shell().info("""
      One pass over the miss list (#{one.repositories} repositories)
        CPU              #{hours(one.cpu_seconds)}
        wall clock       #{hours(one.wall_clock_seconds)} at concurrency #{a.concurrency}
        ingress          #{gb(one.ingress_bytes)}
        stored           #{gb(one.stored_bytes)}

      Keeping it warm for a month, TTL #{a.ttl_days} days, churn #{round(a.churn * 100)}%
        naive     #{estimate.naive_monthly.analyses} analyses, #{hours(estimate.naive_monthly.cpu_seconds)} CPU, #{gb(estimate.naive_monthly.ingress_bytes)} ingress
        watched   #{estimate.watched_monthly.probes} probes (#{hours(estimate.watched_monthly.probe_seconds)}), #{estimate.watched_monthly.analyses} analyses, #{hours(estimate.watched_monthly.cpu_seconds)} CPU, #{gb(estimate.watched_monthly.ingress_bytes)} ingress
      """)

      if rates do
        shell().info("    priced")
        price_line("one pass", one, rates)
        price_line("naive month", estimate.naive_monthly, rates)
        price_line("watched month", estimate.watched_monthly, rates)
      else
        shell().info(
          "    No --rates given, so quantities only. Host rates live in the ops repository."
        )
      end
    else
      shell().info("    Nothing measurable: no repository in the sample analysed.")
    end

    shell().info(
      "\n    sampled: #{Enum.join(Enum.take(sample, 5), ", ")}#{if length(sample) > 5, do: ", ..."}"
    )

    shell().info(
      "    baseline measured #{baseline["measured_at"]}, #{length(baseline["repos_read"] || [])} manifests"
    )
  end

  defp price_line(label, quantities, rates) do
    priced = LeiService.ScanCost.price(quantities, rates)

    detail =
      priced.usd |> Enum.sort() |> Enum.map_join(", ", fn {k, v} -> "#{k} $#{v}" end)

    missing =
      if priced.missing == [], do: "", else: "  (no rate for #{Enum.join(priced.missing, ", ")})"

    shell().info(
      "      #{String.pad_trailing(label, 15)} $#{priced.total_usd}   #{detail}#{missing}"
    )
  end

  defp col(%{median: nil}), do: "     n/a       n/a       n/a"

  defp col(%{median: median, mean: mean, max: max}) do
    [median, mean, max]
    |> Enum.map_join("", fn v ->
      String.pad_leading(:erlang.float_to_binary(v / 1, decimals: 1), 10)
    end)
  end

  defp col(%{median: nil}, _unit), do: "     n/a       n/a       n/a"

  defp col(%{median: median, mean: mean, max: max}, unit) do
    [median, mean, max]
    |> Enum.map_join("", fn v -> String.pad_leading(size(v, unit), 10) end)
  end

  defp size(bytes, :mb), do: "#{Float.round(bytes / 1_000_000, 1)}MB"
  defp size(bytes, :kb), do: "#{Float.round(bytes / 1_000, 1)}KB"

  # Adaptive, because a corpus cost spans four orders of magnitude between a
  # sample run and a fifty-thousand-repository preload, and "0.0 GB" for 1.6 MB
  # of reports reads as nothing at all.
  defp gb(bytes) when bytes < 1_000_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  defp gb(bytes) when bytes < 1_000_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp gb(bytes), do: "#{Float.round(bytes / 1_000_000_000, 2)} GB"

  defp hours(seconds) when seconds < 120, do: "#{Float.round(seconds / 1, 1)}s"
  defp hours(seconds) when seconds < 7200, do: "#{Float.round(seconds / 60, 1)}m"
  defp hours(seconds), do: "#{Float.round(seconds / 3600, 1)}h"
end
