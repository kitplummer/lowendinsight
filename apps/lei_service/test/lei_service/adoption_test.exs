defmodule LeiService.AdoptionTest do
  @moduledoc """
  Which clients actually call the analysis.

  The MCP server exists on the theory that an agent reaches for this while
  deciding what to depend on. Nothing measured whether that happens, so the
  question could only be answered with an opinion — and the answer decides
  whether the distribution work is worth continuing.

  Two failures are guarded here, and the first is the dangerous one.

  **Cardinality.** The client comes from a request header, so label values are
  chosen by whoever is calling. A counter labelled with the raw user agent lets
  one caller mint unbounded series until `/metrics` grows past its scrape
  timeout, taking every other signal with it — the monitor, the billing mode,
  the switches, the reconciliation.

  **A window that could not be read is not a window of zeros.** "No agent has
  ever called this" and "we could not tell" are opposite findings, and the first
  is the entire question.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.Adoption

  @opts LeiService.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    # Yesterday, so these counts cannot collide with another test's today.
    day = Date.add(Date.utc_today(), -1)

    on_exit(fn ->
      for bucket <- Adoption.buckets() do
        Redix.command(:redix, ["DEL", "adoption:#{bucket}:#{Date.to_iso8601(day)}"])
      end
    end)

    %{day: day}
  end

  describe "bucketing is bounded by us, not by the caller" do
    test "a caller cannot mint a new label value" do
      # The one that matters. A hundred hostile user agents must collapse into
      # the fixed set, or /metrics is a denial of service with a header.
      hostile =
        for i <- 1..100 do
          "evil-#{i}/#{String.duplicate("x", 50)}"
        end

      buckets = hostile |> Enum.map(&Adoption.bucket/1) |> Enum.uniq()

      assert buckets == ["other"],
             "a caller produced label values of its own: #{inspect(buckets)}"

      assert Enum.all?(hostile, &(Adoption.bucket(&1) in Adoption.buckets()))
    end

    test "an absent user agent is a bucket, not a disappearance" do
      assert Adoption.bucket(nil) == "none"
      assert Adoption.bucket("") == "none"
      assert "none" in Adoption.buckets()
    end

    test "the clients we care about are told apart" do
      assert Adoption.bucket("lowendinsight-mcp/0.1.0") == "mcp"
      assert Adoption.bucket("curl/8.5.0") == "script"
      assert Adoption.bucket("Mozilla/5.0 (X11) Chrome/120") == "browser"
      assert Adoption.bucket("Claude-User/1.0") == "agent"
    end

    test "every bucket bucket/1 can return is declared" do
      # buckets/0 is what the metric iterates. A bucket reachable by bucket/1 but
      # missing from buckets/0 would never be published, so calls from it would
      # read as zero.
      samples = [
        nil,
        "",
        "lowendinsight-mcp/1",
        "lowendinsight-cli/1",
        "lowendinsight",
        "cursor/1",
        "curl/8",
        "Mozilla/5.0",
        "whatever"
      ]

      for sample <- samples do
        assert Adoption.bucket(sample) in Adoption.buckets(),
               "#{inspect(sample)} buckets to #{Adoption.bucket(sample)}, which is not declared"
      end
    end
  end

  describe "counting" do
    test "a call is counted against its bucket", %{day: day} do
      Adoption.record("lowendinsight-mcp/0.1.0", day)
      Adoption.record("lowendinsight-mcp/0.1.0", day)
      Adoption.record("curl/8", day)

      {:ok, counts} = Adoption.window(2)

      assert counts["mcp"] >= 2
      assert counts["script"] >= 1
    end

    test "every bucket appears in the window, including the empty ones" do
      # A bucket that vanished when it had no calls would read as a client we do
      # not count rather than one nobody used.
      {:ok, counts} = Adoption.window(1)

      for bucket <- Adoption.buckets() do
        assert Map.has_key?(counts, bucket), "#{bucket} is missing from the window"
      end
    end
  end

  describe "the analysis routes are the ones counted" do
    test "an analysis request is recorded" do
      before = counts_now()

      conn(:post, "/v1/analyze", Poison.encode!(%{urls: ["https://github.com/o/r"]}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("user-agent", "lowendinsight-mcp/test")
      |> LeiService.Endpoint.call(@opts)

      assert counts_now()["mcp"] > before["mcp"],
             "an analysis call from the MCP client was not counted"
    end

    test "a metrics scrape is not recorded as adoption" do
      # /metrics is scraped every fifteen minutes. Counting it would bury the
      # handful of calls the question is about under our own monitoring.
      before = counts_now()

      conn(:get, "/metrics")
      |> put_req_header("user-agent", "lowendinsight-mcp/test")
      |> LeiService.Endpoint.call(@opts)

      assert counts_now()["mcp"] == before["mcp"],
             "a metrics scrape was counted as adoption"
    end

    test "a readiness probe is not recorded as adoption" do
      before = counts_now()

      conn(:get, "/readyz")
      |> put_req_header("user-agent", "kube-probe/1.0")
      |> LeiService.Endpoint.call(@opts)

      assert counts_now()["other"] == before["other"]
    end

    defp counts_now do
      {:ok, counts} = Adoption.window(1)
      counts
    end
  end

  describe "when Redis does not answer" do
    @dead :dead_redix_for_adoption

    setup do
      {:ok, _} =
        Redix.start_link(
          host: "127.0.0.1",
          port: 1,
          name: @dead,
          sync_connect: false,
          exit_on_disconnection: false,
          backoff_max: 100
        )

      previous = Application.get_env(:lei_service, :redix_name)
      Application.put_env(:lei_service, :redix_name, @dead)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:lei_service, :redix_name, previous),
          else: Application.delete_env(:lei_service, :redix_name)
      end)

      :ok
    end

    test "recording does not fail the request" do
      # The counter is worth less than the analysis it counts.
      assert Adoption.record("lowendinsight-mcp/1") == :ok
    end

    test "the window is an error, not a row of zeros" do
      assert {:error, _} = Adoption.window(30)
    end

    test "the metric says it could not be read, rather than publishing zeros" do
      metrics = Lei.Metrics.collect()

      assert metrics =~ "lei_adoption_readable 0"

      refute metrics =~ "lei_adoption_calls{",
             "an unreadable counter published a call count, which reads as 'nobody uses it'"
    end
  end
end
