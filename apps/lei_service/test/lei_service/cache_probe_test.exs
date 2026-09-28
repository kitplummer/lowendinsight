defmodule LeiService.CacheProbeTest do
  @moduledoc """
  The read-only cache probe, and the arithmetic built on it.

  This exists to measure one number: what fraction of a real manifest is already
  cached (lei_ops/product/critical-mass.md). Every failure mode here has the same
  shape -- a plausible number over nothing -- which is the shape this repository
  keeps shipping, so each is driven rather than read.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.ApiKeys
  alias LeiService.CacheBaseline, as: Baseline
  alias LeiService.Datastore

  @opts LeiService.Endpoint.init([])
  @cached "https://github.com/kitplummer/probe-cached-#{System.unique_integer([:positive])}"
  @absent "https://github.com/kitplummer/probe-absent-#{System.unique_integer([:positive])}"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    {:ok, org} =
      ApiKeys.find_or_create_org("Probe #{System.unique_integer([:positive])}", status: "active")

    {:ok, cache_key, _} = ApiKeys.create_api_key(org, "cache", ["cache"])
    {:ok, plain_key, _} = ApiKeys.create_api_key(org, "plain", ["analyze"])

    Datastore.write_to_cache(@cached, %{"data" => %{"risk" => "low"}})
    on_exit(fn -> Datastore.delete_from_cache(@cached) end)

    %{cache_key: cache_key, plain_key: plain_key}
  end

  defp probe(key, payload) do
    conn(:post, "/v1/cache/probe", Poison.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> then(fn c -> if key, do: put_req_header(c, "authorization", "Bearer #{key}"), else: c end)
    |> LeiService.Endpoint.call(@opts)
  end

  describe "the answer" do
    test "a cached repository is a hit and an uncached one is a miss", %{cache_key: key} do
      conn = probe(key, %{urls: [@cached, @absent]})

      assert conn.status == 200
      body = Poison.decode!(conn.resp_body)

      assert body["total"] == 2
      assert body["hits"] == 1
      assert body["misses"] == 1
      assert body["results"][@cached] == true
      assert body["results"][@absent] == false
    end

    test "probing does not cache what it probed", %{cache_key: key} do
      # The whole point. Measuring by analysing would populate the cache as it
      # read it, so the first repository measured is the last honest one.
      probe(key, %{urls: [@absent]})

      refute Datastore.in_cache?(@absent)
    end

    test "an empty list is refused rather than answered 0 of 0", %{cache_key: key} do
      conn = probe(key, %{urls: []})

      assert conn.status == 422
    end

    test "a list over the limit is refused", %{cache_key: key} do
      urls = for n <- 1..501, do: "https://github.com/o/r#{n}"
      conn = probe(key, %{urls: urls})

      assert conn.status == 422
      assert Poison.decode!(conn.resp_body)["limit"] == 500
    end
  end

  describe "authorisation" do
    test "requires a key" do
      assert probe(nil, %{urls: [@absent]}).status == 401
    end

    test "an analyze-scoped key cannot enumerate the corpus", %{plain_key: key} do
      conn = probe(key, %{urls: [@absent]})

      assert conn.status == 403
    end
  end

  describe "a cache it cannot read is not a cache full of misses" do
    @dead :dead_redix_for_probe

    setup do
      # Port 1 is reserved, so every command fails with a connection error.
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

    test "probe_cache/1 returns an error, not a map of falses" do
      # in_cache?/1 answers false here, which is right for the analysis path and
      # wrong for measurement: folded into a hit rate it reads as "nothing is
      # cached" -- a number where there is no measurement.
      assert {:error, _} = Datastore.probe_cache(["https://github.com/o/r"])
    end

    test "the endpoint answers 503 rather than reporting every url a miss", %{cache_key: key} do
      conn = probe(key, %{urls: ["https://github.com/o/r"]})

      assert conn.status == 503
      assert Poison.decode!(conn.resp_body)["error"] =~ "cache unavailable"
    end
  end

  describe "what the SBOM names" do
    @sbom %{
      "sbom" => %{
        "packages" => [
          %{
            "name" => "com.github.expressjs/express",
            "externalRefs" => [
              %{"referenceType" => "purl", "referenceLocator" => "pkg:github/expressjs/express"}
            ]
          },
          %{
            "name" => "debug",
            "externalRefs" => [
              %{"referenceType" => "purl", "referenceLocator" => "pkg:npm/debug@2.6.9"}
            ]
          },
          %{
            "name" => "actions/checkout",
            "externalRefs" => [
              %{
                "referenceType" => "purl",
                "referenceLocator" => "pkg:githubactions/actions/checkout@4"
              }
            ]
          },
          %{
            "name" => "@types/node",
            "externalRefs" => [
              %{"referenceType" => "purl", "referenceLocator" => "pkg:npm/%40types/node@20.0.0"}
            ]
          }
        ]
      }
    }

    test "the repository is not counted as a dependency of itself" do
      packages = Baseline.packages(@sbom, "expressjs/express")

      refute Enum.any?(packages, &(&1.ecosystem == "github")),
             "the subject repository was counted, which credits every manifest with a hit"
    end

    test "a scoped npm name keeps its scope" do
      packages = Baseline.packages(@sbom, "expressjs/express")

      assert Enum.any?(packages, &(&1.package == "@types/node")),
             "the npm scope was dropped: #{inspect(Enum.map(packages, & &1.package))}"
    end

    test "a githubactions purl resolves to its repository without a lookup" do
      # Found by running it. Dropping the namespace turned every
      # pkg:githubactions/actions/checkout into "checkout", and the ecosystem
      # reported 0% coverage -- which reads as a finding rather than a bug.
      [action] =
        Enum.filter(
          Baseline.packages(@sbom, "expressjs/express"),
          &(&1.ecosystem == "githubactions")
        )

      assert Baseline.route(action) == {:direct, "https://github.com/actions/checkout"}
    end

    test "a registry purl is routed to a lookup, not guessed at" do
      [debug] =
        Enum.filter(
          Baseline.packages(@sbom, "expressjs/express"),
          &(&1.ecosystem == "npm" and &1.package == "debug")
        )

      assert Baseline.route(debug) == {:registry, "npm", "debug"}
    end

    test "an ecosystem we cannot resolve is refused, not pattern-matched into a URL" do
      assert {:error, {:unsupported_ecosystem, "golang"}} =
               Baseline.route(%{ecosystem: "golang", package: "github.com/gin-gonic/gin"})
    end
  end

  describe "the rates" do
    defp entry(ecosystem, package, repository),
      do: %{ecosystem: ecosystem, package: package, repository: repository}

    test "the hit rate is over resolved repositories, and coverage is reported beside it" do
      entries = [
        entry("npm", "a", {:ok, "https://github.com/o/a"}),
        entry("npm", "b", {:ok, "https://github.com/o/b"}),
        entry("npm", "c", {:error, :no_repository})
      ]

      counts = Baseline.counts(entries, MapSet.new(["https://github.com/o/a"]))

      assert counts.packages == 3
      assert counts.resolved_packages == 2
      assert counts.repositories == 2
      assert counts.hits == 1
      assert counts.hit_rate == 50.0
      assert counts.coverage == 66.7
    end

    test "no resolved packages gives no rate, not 0%" do
      counts = Baseline.counts([entry("npm", "c", {:error, :no_repository})], MapSet.new())

      assert counts.hit_rate == nil,
             "a run that resolved nothing reported a hit rate, which is a number where there is no measurement"
    end

    test "resolved but uncached is 0%, which must not read like 'no measurement'" do
      counts = Baseline.counts([entry("npm", "a", {:ok, "https://github.com/o/a"})], MapSet.new())

      assert counts.hit_rate == 0.0
    end

    test "two packages sharing one repository count once" do
      # A monorepo publishes many packages from one repository; counting the
      # repository twice inflates both the denominator and the hits.
      entries = [
        entry("npm", "a", {:ok, "https://github.com/o/mono"}),
        entry("npm", "b", {:ok, "https://github.com/o/mono"})
      ]

      counts = Baseline.counts(entries, MapSet.new(["https://github.com/o/mono"]))

      assert counts.repositories == 1
      assert counts.hits == 1
      assert counts.hit_rate == 100.0

      assert counts.resolved_packages == 2,
             "two packages sharing a repository were reported as one resolved package, " <>
               "so deduplication reads as a failure to resolve"

      assert counts.coverage == 100.0
    end

    test "a registry that would not answer is counted apart from a package with no repository" do
      # A rate-limited registry understates coverage, and understated coverage
      # reads as a finding about the ecosystem rather than about our network.
      entries = [
        entry("npm", "a", {:error, :no_repository}),
        entry("npm", "b", {:error, {:unreachable, :closed}}),
        entry("npm", "c", {:error, {:status, 429}})
      ]

      counts = Baseline.counts(entries, MapSet.new())

      assert counts.no_repository == 1
      assert counts.lookup_failed == 2
    end
  end

  describe "the scheduled measurement" do
    # The task's own guards (--min-repos, --max-lookup-failures) are what stop a
    # degraded run from publishing a number. A workflow that stopped passing
    # them would still be green, and the number in the run summary would still
    # look like a measurement -- so the flags are part of the contract.
    @workflow Path.expand("../../../../.github/workflows/cache-baseline.yml", __DIR__)

    setup do
      %{yaml: File.read!(@workflow)}
    end

    test "it measures production, not the runner's empty cache", %{yaml: yaml} do
      assert yaml =~ "--probe-url https://lowendinsight.dev"
    end

    test "it refuses to report a rate measured over a handful of manifests", %{yaml: yaml} do
      assert yaml =~ ~r/--min-repos \d+/,
             "the run would publish a hit rate however few SBOMs it managed to read"
    end

    test "it fails when our own lookups degraded the coverage", %{yaml: yaml} do
      assert yaml =~ ~r/--max-lookup-failures \d+/
    end

    test "a missing key fails the job rather than measuring nothing", %{yaml: yaml} do
      assert yaml =~ "LEI_ADMIN_API_KEY is not set"
    end
  end
end
