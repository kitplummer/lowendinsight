defmodule Lei.Batch do
  require Logger

  @moduledoc """
  A batch of dependencies: validated, priced, run, and billed for what ran.

  `POST /v1/analyze/batch` was the only caller, and all of this lived in its
  route. It moved here so a second entry point -- MCP's `check_packages` --
  runs the same validation, the same price and the same refund of work that
  never reached the queue. Two copies of a billing path drift, and the copy
  that drifts is the one nobody is testing (#147).

  Admission sits between `price/2` and `run/4` and stays with the caller: who
  is asked to pay, and how they are told, differs by protocol.
  """

  @doc """
  `{:ok, dependencies, opts}`, `{:too_many, body}` for a request over the
  repository cap (rendered as a 422 with the count and the limit), or
  `{:error, message}`.
  """
  def validate(params) do
    dependencies = params["dependencies"]

    # The third entry point that names a list of repositories. The other two
    # share urls_analyzable/1 in the endpoint; this one has its own validation,
    # and a cap missing from one route is a cap nobody has (ADR-008). Returned
    # as its own tag so it renders as a 422 with the count and the limit, like
    # the other two, rather than as a bare 400 string.
    with :ok <- Lei.RequestScope.check(List.wrap(dependencies)) do
      validate_batch_dependencies(dependencies, params)
    else
      {:error, body} -> {:too_many, body}
    end
  end

  @doc """
  `{{cache_hits, cache_misses}, admission}`: the split, and the options
  `Lei.Payments.Gate` admits it with. Admission without a price let a batch of
  any size through for an org that could afford one analysis.
  """
  def price(dependencies, opts) do
    {hits, misses} = Lei.BatchAnalyzer.cache_split(dependencies, opts)

    admission = [
      required_credits: Lei.Credits.cost_in_credits(hits, misses),
      usage: {hits, misses}
    ]

    {{hits, misses}, admission}
  end

  @doc """
  Runs an admitted batch for `{org_id, tier}`, which was charged at admission
  for `{hits, misses}`, and returns the result with its billing block.
  """
  def run(dependencies, opts, {org_id, tier}, {hits, misses}) do
    # The library has no queue: it schedules through this (ADR-004).
    result = Lei.BatchAnalyzer.analyze(dependencies, [schedule: scheduler(org_id)] ++ opts)

    cost = Lei.UsageTracker.calculate_cost(hits, misses)

    # Admission charged for every miss, before any job existed (#152).
    # Anything that did not reach the queue is given back: the ledger
    # write and the Oban insert go through different repos and cannot
    # share a transaction, so the money follows the work rather than
    # committing with it (#217).
    # Not summary.failed: that includes dependencies already recorded
    # as unresolvable, which admission never charged for.
    unqueued = get_in(result, [:summary, :unqueued]) || 0
    credited = credit_unqueued(org_id, unqueued)

    Map.put(result, :billing, %{
      cache_hits: hits,
      cache_misses: misses,
      cost_cents: Decimal.to_float(cost),
      unqueued: unqueued,
      credited_back_cents: credited,
      tier: tier || "unknown"
    })
  end

  defp validate_batch_dependencies(dependencies, params) do
    cond do
      is_nil(dependencies) ->
        {:error, "missing required field: dependencies"}

      not is_list(dependencies) ->
        {:error, "dependencies must be an array"}

      Enum.empty?(dependencies) ->
        {:error, "dependencies must not be empty"}

      not Enum.all?(dependencies, &valid_dependency?/1) ->
        {:error, "each dependency must have ecosystem, package, and version fields"}

      true ->
        opts = [
          cache_mode: params["cache_mode"] || "stale",
          include_transitive: params["include_transitive"] || false
        ]

        {:ok, dependencies, opts}
    end
  end

  # One job per uncached dependency, returning the job's own id so a caller
  # can poll work that exists. Oban's uniqueness means a dependency already
  # queued in the last 15 minutes returns that job rather than a second one.
  # Overridable so a failure to enqueue can be exercised without breaking Oban
  # itself. The queue belongs to the caller of the library (ADR-004), and this
  # is that caller.
  # The scheduler carries the org so the worker can credit back an analysis
  # that determines nothing (#258). Admission charged for it before any
  # analysis ran, and the outcome is only known later, so the refund needs to
  # reach whoever paid.
  defp scheduler(org_id) do
    Application.get_env(:lei_service, :batch_scheduler) ||
      fn dep -> enqueue_dependency(dep, org_id) end
  end

  # Credits back what was charged for and never queued (#217). The shared
  # helper writes the entry; this decides how much and reports it.
  defp credit_unqueued(_org_id, 0), do: 0.0

  defp credit_unqueued(org_id, unqueued) when unqueued > 0 do
    credits = Lei.Credits.cost_in_credits(0, unqueued)

    case Lei.Credits.credit_unqueued(org_id, credits, %{"unqueued" => unqueued}) do
      {:ok, _} -> Lei.UsageTracker.calculate_cost(0, unqueued) |> Decimal.to_float()
      {:error, _reason} -> 0.0
    end
  end

  defp enqueue_dependency(dep, org_id) do
    %{
      "ecosystem" => dep["ecosystem"],
      "package" => dep["package"],
      "version" => dep["version"],
      "org_id" => org_id
    }
    |> LeiService.BatchDependencyWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, job} ->
        {:ok, to_string(job.id)}

      {:error, reason} ->
        Logger.error(
          "batch: could not queue #{dep["ecosystem"]}/#{dep["package"]}: #{inspect(reason)}"
        )

        {:error, :not_queued}
    end
  end

  defp valid_dependency?(dep) when is_map(dep) do
    is_binary(dep["ecosystem"]) and is_binary(dep["package"]) and is_binary(dep["version"])
  end

  defp valid_dependency?(_), do: false
end
