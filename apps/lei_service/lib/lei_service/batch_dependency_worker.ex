defmodule LeiService.BatchDependencyWorker do
  @moduledoc """
  Analyses one dependency from a batch request.

  A batch names packages; an analysis needs a repository. This resolves the
  package through its registry (`Lei.PackageRepository`), analyses what it
  finds, and writes the report into the batch cache under the coordinate, so
  the next request for it is a hit.

  Before this, a miss was marked "pending" with a generated id and nothing was
  queued: the analysis the caller was charged for never ran (ADR-004 step 4).

  A failure that another attempt cannot fix -- an ecosystem we do not resolve,
  a package the registry does not have, a package with no repository -- is
  cancelled rather than retried. A registry that is unreachable is retried.
  """

  use Oban.Worker,
    queue: :analysis,
    max_attempts: 3,
    unique: [period: 900, fields: [:args], keys: [:ecosystem, :package, :version]]

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(20)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"ecosystem" => eco, "package" => package, "version" => version} = args
      }) do
    case resolve().(eco, package, []) do
      {:ok, url} ->
        analyse(eco, package, version, url, args["org_id"])

      # Nothing about a retry changes these answers.
      {:error, reason} when reason in [:no_repository, :not_found] ->
        {:cancel, "#{eco}/#{package}: #{inspect(reason)}"}

      {:error, {:unsupported_ecosystem, _} = reason} ->
        {:cancel, "#{eco}/#{package}: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "#{eco}/#{package}: #{inspect(reason)}"}
    end
  end

  defp analyse(eco, package, version, url, org_id) do
    case analyze().(url) do
      {:ok, report} ->
        if AnalyzerModule.determined?(report) do
          Lei.BatchCache.put(eco, package, version, report)
          Logger.info("batch dependency analysed: #{eco}/#{package}@#{version}")
          :ok
        else
          undetermined(eco, package, org_id)
        end

      other ->
        {:error, "#{eco}/#{package}: analysis returned #{inspect(other)}"}
    end
  end

  # An analysis that ran and determined nothing. Two things follow, and #256
  # only did the first of them on the other analysis path -- this cache has
  # its own `put` and kept the defect.
  #
  # It is not cached, so a transient failure does not become a day-long answer
  # and the next request is a real attempt. And the requester is credited back:
  # admission charged a cache miss for this before any analysis ran (#258), and
  # they received a report whose every metric is nil.
  #
  # The job succeeds. One unanalysable dependency in a manifest of two hundred
  # must not retry forever or fail the rest, and nothing about a retry would
  # change the answer.
  defp undetermined(eco, package, org_id) do
    Logger.warning("batch dependency determined nothing: #{eco}/#{package}; not caching")

    credits = Lei.Credits.cost_in_credits(0, 1)

    case org_id do
      nil ->
        # Enqueued before org_id was carried, or by a path that has no org.
        # Nothing to credit, and pretending otherwise would write an entry
        # against nobody.
        Logger.warning("batch dependency determined nothing with no org to credit")
        :ok

      id ->
        Lei.Credits.credit_undetermined(id, credits, %{
          "undetermined" => 1,
          "ecosystem" => eco,
          "package" => package
        })

        :ok
    end
  end

  defp resolve do
    config(:resolve, fn eco, package, opts ->
      Lei.PackageRepository.resolve(eco, package, opts)
    end)
  end

  defp analyze do
    config(:analyze, fn url -> AnalyzerModule.analyze(url, "lei-batch", %{types: true}) end)
  end

  defp config(key, default) do
    :lei_service
    |> Application.get_env(:batch_dependency, [])
    |> Keyword.get(key, default)
  end
end
