defmodule LowendinsightGet.JobAccessTest do
  @moduledoc """
  A job's id is the credential for reading it, and reading it does not start
  unbounded work.

  Found in the 2026-09-14 security review:
  - job ids were UUIDv1 (a timestamp and 14 random bits), and any API key could
    read any job -- which repositories someone else submitted;
  - the id was used directly as a Redis key, so any JSON value in that database
    could be read through the job route;
  - every poll of an incomplete job re-started analysis of its uncached URLs,
    so a repository that keeps failing was re-cloned on every request;
  - a failure answered with the exception's message.

  Decided 2026-09-15: the id is the credential (random UUIDv4), rather than an
  owner check, which would store the payer-to-analysis link #149 decided
  against keeping.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.ApiKeys
  alias LowendinsightGet.Datastore

  @opts LowendinsightGet.Endpoint.init([])
  @uuid4 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()
    LowendinsightGet.Plugs.RateLimiter.clear()

    {:ok, org} =
      ApiKeys.create_org("Job Access #{System.unique_integer([:positive])}",
        tier: "pro",
        status: "active"
      )

    {:ok, key, _} = ApiKeys.create_api_key(org, "jobs", ["analyze"])

    original = Application.get_env(:lowendinsight_get, :job_refresher)

    on_exit(fn ->
      if original,
        do: Application.put_env(:lowendinsight_get, :job_refresher, original),
        else: Application.delete_env(:lowendinsight_get, :job_refresher)
    end)

    %{key: key}
  end

  defp get(path, key) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer " <> key)
    |> LowendinsightGet.Endpoint.call(@opts)
  end

  defp cached_url do
    url = "https://github.com/kitplummer/job-access-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Datastore.write_to_cache(url, %{
      data: %{repo: url},
      header: %{end_time: now, start_time: now, uuid: "c"}
    })

    url
  end

  test "a new API job's id is a random UUIDv4", %{key: key} do
    conn =
      conn(:post, "/v1/analyze", %{"urls" => [cached_url()], "cache_mode" => "async"})
      |> put_req_header("authorization", "Bearer " <> key)
      |> LowendinsightGet.Endpoint.call(@opts)

    assert conn.status in [200, 202], conn.resp_body
    uuid = Poison.decode!(conn.resp_body)["uuid"]
    assert uuid =~ @uuid4, "job id #{inspect(uuid)} is not a UUIDv4"
  end

  test "an id that is not a UUID reads nothing from Redis", %{key: key} do
    {:ok, _} =
      Redix.command(:redix, [
        "SET",
        "job-access-not-a-job",
        ~s({"state":"complete","planted":"readable"})
      ])

    on_exit(fn -> Redix.command(:redix, ["DEL", "job-access-not-a-job"]) end)

    for route <- ["/v1/analyze/job-access-not-a-job", "/v1/job/job-access-not-a-job"] do
      conn = get(route, key)
      assert conn.status == 404, route
      refute conn.resp_body =~ "planted"
    end
  end

  test "polling an incomplete job starts work at most once per window", %{key: key} do
    test_pid = self()

    Application.put_env(:lowendinsight_get, :job_refresher, fn job ->
      send(test_pid, :refreshed)
      job
    end)

    uuid = UUID.uuid4()

    job = %{
      "uuid" => uuid,
      "state" => "incomplete",
      "report" => %{"repos" => []},
      "metadata" => %{}
    }

    {:ok, _} = Datastore.write_job(uuid, job)
    on_exit(fn -> Redix.command(:redix, ["DEL", uuid, "job_refresh:" <> uuid]) end)

    for _ <- 1..3, do: assert(get("/v1/analyze/" <> uuid, key).status == 200)

    assert_received :refreshed
    refute_received :refreshed
  end

  test "a failure does not return the exception's message", %{key: key} do
    uuid = UUID.uuid4()
    {:ok, _} = Redix.command(:redix, ["SET", uuid, "this is not json"])
    on_exit(fn -> Redix.command(:redix, ["DEL", uuid]) end)

    conn = get("/v1/analyze/" <> uuid, key)

    assert conn.status == 500
    refute conn.resp_body =~ "unexpected"
    refute conn.resp_body =~ "details"
  end
end
