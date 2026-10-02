defmodule Lei.RequestScope do
  @moduledoc """
  How many repositories one request may name (ADR-008, question 2).

  Before this, the only bound was the org's remaining quota — a billing control
  doing a capacity control's job. In beta the free-tier allowance was the sole
  thing between us and a 3,580-repository manifest; once billing is on, a funded
  org can ask for ten thousand in a single call.

  ## Where the number comes from

  Not disk, and not memory. Neither scales with the size of a request: clones go
  through the analysis queue a few at a time, so peak disk is concurrency times
  per-clone whatever the request names, and a report is small enough that even a
  thousand of them is a low single-digit percentage of the cache budget.

  What does scale is **how long one request owns the queue**. The analysis queue
  runs at `OBAN_ANALYSIS_CONCURRENCY` (5 in production). A request naming N
  repositories occupies all of it for roughly `N / 5 × per-analysis`, and
  everything behind it waits. A 3,580-repository manifest is about twenty
  minutes of that, during which every other customer is starved — and nothing
  reports it, because each request eventually succeeds.

  So the cap is the point where one request can no longer hold the queue longer
  than the service already permits a single request to take:

      concurrency 5 × idle_timeout 180 s ÷ p90 analysis 1.62 s  ≈  555

  `idle_timeout` is Cowboy's, already chosen for blocking analysis
  (`endpoint.ex`), and p90 comes from measuring fifty-nine repositories drawn
  from real manifests. The default is **500**, that derivation rounded down for
  headroom rather than up for generosity.

  **Re-derive it if the concurrency changes.** A higher concurrency earns a
  higher cap; raising the cap alone just lets one caller wait longer while
  holding everyone else.

  The value is configuration (`LEI_MAX_REPOS_PER_REQUEST`), because what we are
  willing to let one request do to the queue is an operating choice, not a
  property of the code.
  """

  @doc """
  The cap. Zero or a negative value means unlimited, for a deployment with its
  own queue and its own judgement about it (ADR-003: the library and service are
  separable, and a self-hoster's capacity is theirs).
  """
  @spec max_repositories() :: integer()
  def max_repositories do
    Application.get_env(:lei_service, :max_repositories_per_request, 500)
  end

  @doc """
  `:ok`, or `{:error, map}` ready to serve as a 422 body.

  The refusal names the count and the cap, because an agent that is told only
  "too many" cannot decide how to split the work, and splitting it is the
  correct response.
  """
  @spec check(list() | non_neg_integer()) :: :ok | {:error, map()}
  def check(repositories) when is_list(repositories), do: check(length(repositories))

  def check(count) when is_integer(count) do
    cap = max_repositories()

    cond do
      cap <= 0 ->
        :ok

      count > cap ->
        {:error,
         %{
           error: "too_many_repositories",
           message:
             "this request names #{count} repositories and the limit is #{cap}. " <>
               "Split it into batches of #{cap} or fewer.",
           limit: cap,
           received: count
         }}

      true ->
        :ok
    end
  end
end
