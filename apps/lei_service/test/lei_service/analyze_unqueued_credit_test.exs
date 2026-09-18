defmodule LeiService.AnalyzeUnqueuedCreditTest do
  @moduledoc """
  An analysis that could not be queued is not paid for (#217).

  `/v1/analyze` and `/v1/analyze/sbom` charge at admission, before any work
  exists (#152). The work is then handed to Oban through a different repo, and
  when that insert failed `perform_analysis/3` raised -- so the caller was
  charged, got a bare 500 from `Plug.ErrorHandler`, and no job existed.

  The batch route had the same gap and was fixed first (#233); it could report
  per-dependency failures, so it credits back only the ones that did not queue.
  These two routes queue the whole request or none of it, so the whole charge
  comes back.

  The failure is produced the way it would really happen -- the insert hits the
  database and fails -- by removing the table inside the test's own
  transaction, which rolls back with everything else. A stub would assert that
  the rescue clause runs, not that a real Oban failure reaches it.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.{ApiKeys, Credits, Repo}

  @opts LeiService.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LeiService.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(LeiService.Repo, {:shared, self()})
    Lei.RateLimiter.clear()

    saved = Application.get_env(:lei_service, :use_workers)
    Application.put_env(:lei_service, :use_workers, true)

    on_exit(fn ->
      if is_nil(saved),
        do: Application.delete_env(:lei_service, :use_workers),
        else: Application.put_env(:lei_service, :use_workers, saved)
    end)

    {:ok, org} =
      ApiKeys.find_or_create_org("Unqueueable #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    {:ok, raw_key, _api_key} = ApiKeys.create_api_key(org, "k", ["analyze"])

    %{org: org, key: raw_key}
  end

  # The real failure mode: Oban's insert reaches the database and cannot
  # complete. Inside the test transaction, so it is undone with it.
  defp break_the_queue! do
    Ecto.Adapters.SQL.query!(LeiService.Repo, "DROP TABLE oban_jobs CASCADE", [])
  end

  defp post(path, body, key) do
    conn(:post, path, Poison.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> LeiService.Endpoint.call(@opts)
  end

  defp credited(org_id) do
    org_id
    |> Credits.entries()
    |> Enum.filter(&(&1.reason == "adjustment:unqueued"))
    |> Enum.map(& &1.delta)
    |> Enum.sum()
  end

  describe "POST /v1/analyze" do
    test "credits back the whole charge when the work cannot be queued", ctx do
      break_the_queue!()

      conn =
        post("/v1/analyze", %{"urls" => ["https://github.com/kitplummer/xmpp4rails"]}, ctx.key)

      # Not a bare 500: the caller is told the work was not accepted.
      assert conn.status == 503
      body = Poison.decode!(conn.resp_body)
      assert body["error"] == "analysis_not_queued"

      # Charged at admission, given back in full.
      assert credited(ctx.org.id) > 0
      assert Credits.balance(ctx.org.id) == 0
    end

    test "charges normally when the work does queue", ctx do
      conn =
        post("/v1/analyze", %{"urls" => ["https://github.com/kitplummer/xmpp4rails"]}, ctx.key)

      assert conn.status in [200, 202]
      assert credited(ctx.org.id) == 0
      assert Credits.balance(ctx.org.id) < 0
    end
  end

  describe "POST /v1/analyze/sbom" do
    @sbom %{
      "bomFormat" => "CycloneDX",
      "specVersion" => "1.4",
      "components" => [
        %{
          "type" => "library",
          "name" => "xmpp4rails",
          "purl" => "pkg:github/kitplummer/xmpp4rails@1.0"
        }
      ]
    }

    test "credits back the whole charge when the work cannot be queued", ctx do
      break_the_queue!()

      conn = post("/v1/analyze/sbom", %{"sbom" => @sbom}, ctx.key)

      assert conn.status == 503
      assert Poison.decode!(conn.resp_body)["error"] == "analysis_not_queued"
      assert credited(ctx.org.id) > 0
      assert Credits.balance(ctx.org.id) == 0
    end
  end

  describe "the failure is distinguishable" do
    # Rescuing every exception would credit back a request whose work *was*
    # queued and then failed for some other reason, which is free work. Only
    # the enqueue failure is caught.
    test "perform_analysis raises a named error the routes can single out" do
      break_the_queue!()

      assert_raise LeiService.EnqueueError, fn ->
        LeiService.AnalysisSupervisor.perform_analysis(
          UUID.uuid4(),
          ["https://github.com/kitplummer/xmpp4rails"],
          DateTime.utc_now()
        )
      end
    end
  end
end
