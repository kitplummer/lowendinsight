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
  def perform(%Oban.Job{args: %{"ecosystem" => eco, "package" => package, "version" => version}}) do
    case resolve().(eco, package, []) do
      {:ok, url} ->
        analyse(eco, package, version, url)

      # Nothing about a retry changes these answers.
      {:error, reason} when reason in [:no_repository, :not_found] ->
        {:cancel, "#{eco}/#{package}: #{inspect(reason)}"}

      {:error, {:unsupported_ecosystem, _} = reason} ->
        {:cancel, "#{eco}/#{package}: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "#{eco}/#{package}: #{inspect(reason)}"}
    end
  end

  defp analyse(eco, package, version, url) do
    case analyze().(url) do
      {:ok, report} ->
        Lei.BatchCache.put(eco, package, version, report)
        Logger.info("batch dependency analysed: #{eco}/#{package}@#{version}")
        :ok

      other ->
        {:error, "#{eco}/#{package}: analysis returned #{inspect(other)}"}
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
