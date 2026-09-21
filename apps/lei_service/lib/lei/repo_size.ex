defmodule Lei.RepoSize do
  @moduledoc """
  Refuses to clone a repository too large to analyse (#265).

  `GithubTrending.keep_repo?/2` has capped candidates at 250 MB since #162,
  when a 1 GB limit on a machine with 459 MB of memory let 671 MB and 411 MB
  repositories through. That guard protects the path **we** drive. The customer
  path had none, so any caller could name a repository of any size and
  `GitModule.clone_repo/2` would fetch all of it into `LEI_BASE_TEMP_DIR` --
  `/tmp`, the root filesystem, no volume and no quota -- alongside up to four
  other clones.

  Clone size tracks history rather than project size: measured on the shipping
  path, `jason` and `poison` each pull around 18 MB for small codebases. A
  monorepo is orders of magnitude beyond that, and five concurrent slots means
  five of them can be in flight.

  ## Refusing rather than degrading

  A shallow clone would bound the fetch and produce *an* answer with different
  meaning: commit currency would survive, contributor counts and functional
  contributors would not. Half a report presented as a report is the failure
  this codebase produces most often, so a repository over the limit is refused
  and says so.

  The refusal carries `data.error`, which `AnalyzerModule.determined?/1`
  already recognises, so it is neither cached nor billed as an analysis (#256).
  That also means the decision is re-made on the next request rather than
  frozen for thirty days, which is right: the repository may shrink, or the
  limit may change.

  ## Unknown size is allowed through

  Deliberately the opposite of trending, which refuses what it cannot measure.
  Trending chooses its own candidates, so refusing an unmeasurable one costs
  nothing. A customer naming a GitLab repository, or any host without a size
  API, is asking a fair question, and refusing it would break far more than it
  protects.

  The consequence is that this guard covers GitHub and nothing else. That is
  most of the exposure and not all of it; bounding the clone itself is the only
  thing that covers the rest, and it is not attempted here.
  """

  require Logger

  @default_max_repo_size_kb 250_000

  @doc "The limit in KB, as GitHub reports size."
  @spec limit_kb() :: pos_integer
  def limit_kb do
    Application.get_env(:lei_service, :max_repo_size_kb, @default_max_repo_size_kb)
  end

  @doc """
  `:ok`, `{:too_large, size_kb, limit_kb}`, or `:unknown`.

  `size_fn` is injectable so this is testable without reaching GitHub; it
  defaults to the same call trending uses.
  """
  @spec check(String.t(), (String.t() -> {integer | nil, String.t()})) ::
          :ok | {:too_large, pos_integer, pos_integer} | :unknown
  def check(url, size_fn \\ &LeiService.GithubTrending.get_repo_size/1) do
    case size_fn.(url) do
      {size, _url} when is_integer(size) ->
        limit = limit_kb()
        if size >= limit, do: {:too_large, size, limit}, else: :ok

      _ ->
        :unknown
    end
  end

  @doc """
  A report recording that the repository was not analysed, and why.

  Shaped like the reports `AnalyzerModule.analyze/3` returns when it cannot
  clone, so everything downstream already handles it: `determined?/1` is false,
  nothing caches it, and nothing bills it as an analysis.

  The size is included because it is the one fact the caller needs to act --
  whether the repository is marginally or hopelessly over.
  """
  @spec refusal(String.t(), pos_integer, pos_integer) :: map
  def refusal(url, size_kb, limit_kb) do
    now = DateTime.utc_now()

    %{
      header: %{
        repo: url,
        start_time: DateTime.to_iso8601(now),
        end_time: DateTime.to_iso8601(now),
        duration: 0,
        uuid: Ecto.UUID.generate(),
        source_client: "lei",
        library_version: Application.spec(:lowendinsight, :vsn) |> to_string()
      },
      data: %{
        error:
          "Repository is too large to analyse: #{size_kb} KB against a limit of #{limit_kb} KB.",
        repo: url,
        git: %{},
        risk: "undetermined",
        project_types: %{"undetermined" => "undetermined"},
        repo_size: size_kb
      }
    }
  end

  @doc """
  Logs a refusal without naming the repository.

  Production does not emit debug, and an info or warning carrying a URL sits in
  the log beside a ledger timestamp, which is enough to put a paying wallet
  next to what it analysed (#149). The size is the operational fact; the
  identity is not.
  """
  @spec log_refusal(pos_integer, pos_integer) :: :ok
  def log_refusal(size_kb, limit_kb) do
    Logger.warning(
      "refusing analysis: repository is #{size_kb} KB against a limit of #{limit_kb} KB"
    )
  end
end
