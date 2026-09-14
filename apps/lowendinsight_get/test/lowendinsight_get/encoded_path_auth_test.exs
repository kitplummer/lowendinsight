defmodule LowendinsightGet.EncodedPathAuthTest do
  @moduledoc """
  A percent-encoded path must meet the same authentication as the plain one.

  Plug.Router decodes each path segment before matching, but both auth plugs,
  the rate limiter and the payment gate decided on the raw request_path. So
  `GET /%761/cache/stats` matched the /v1/cache/stats route while the auth plug
  saw a path without "/v1" in it and let the request through. In production
  that answered 200 with no credentials -- and the same trick reached cache
  export, import and invalidation.

  Every character of every protected path is encoded in turn, so the test does
  not depend on guessing which character a bypass would use.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.ApiKeys

  @opts LowendinsightGet.Endpoint.init([])

  @protected [
    {:get, "/v1/cache/stats"},
    {:get, "/v1/cache/export"},
    {:post, "/v1/cache/import"},
    {:post, "/v1/cache/invalidate"},
    {:post, "/v1/gh_trending/process"},
    {:get, "/v1/job/00000000-0000-0000-0000-000000000000"},
    {:get, "/v1/usage"},
    {:get, "/v1/credits"},
    {:post, "/v1/orgs"},
    {:get, "/v1/orgs/some-org/keys"}
  ]

  # Anonymous callers are asked to pay here rather than refused, so the rule is
  # that an encoding gets exactly the answer the plain path gets.
  @paid [
    {:post, "/v1/analyze"},
    {:post, "/v1/analyze/batch"},
    {:post, "/v1/analyze/sbom"}
  ]

  @cache_routes [
    {:get, "/v1/cache/stats"},
    {:get, "/v1/cache/export"},
    {:post, "/v1/cache/import"},
    {:post, "/v1/cache/invalidate"}
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()
    :ok
  end

  # Each variant encodes exactly one non-slash character, upper and lower hex.
  defp variants(path) do
    chars = String.graphemes(path)

    for {c, i} <- Enum.with_index(chars), c != "/", hex <- [:upper, :lower] do
      encoded = "%" <> Base.encode16(c, case: hex)
      chars |> List.replace_at(i, encoded) |> Enum.join()
    end
  end

  defp request(method, path, key \\ nil) do
    conn =
      conn(method, path, "{}")
      |> put_req_header("content-type", "application/json")

    conn = if key, do: put_req_header(conn, "authorization", "Bearer #{key}"), else: conn
    LowendinsightGet.Endpoint.call(conn, @opts)
  end

  test "the variant generator produces encoded paths" do
    # A generator that produced nothing would make every assertion below pass.
    assert "/%761/cache/stats" in variants("/v1/cache/stats")
    assert length(variants("/v1/cache/stats")) == 2 * 12
  end

  test "no encoding of a protected path is served without credentials" do
    for {method, path} <- @protected, variant <- [path | variants(path)] do
      conn = request(method, variant)

      assert conn.status in [401, 404],
             "#{method} #{variant} answered #{conn.status} without credentials"
    end
  end

  test "the plain protected path is refused with 401, not merely not found" do
    # Guards the assertion above: if every route 404'd, it would pass vacuously.
    for {method, path} <- @protected do
      assert request(method, path).status == 401, "#{method} #{path}"
    end
  end

  test "an encoded paid route gets the plain route's answer" do
    for {method, path} <- @paid do
      plain = request(method, path).status
      refute plain in 200..299, "#{method} #{path} answered #{plain} anonymously"

      for variant <- variants(path) do
        Lei.RateLimiter.clear()
        assert request(method, variant).status == plain, "#{method} #{variant}"
      end
    end
  end

  test "no encoding of a cache route is served to an analyze-only key" do
    {:ok, org} =
      ApiKeys.find_or_create_org("Encoded #{System.unique_integer([:positive])}",
        status: "active"
      )

    {:ok, key, _} = ApiKeys.create_api_key(org, "plain", ["analyze"])

    for {method, path} <- @cache_routes, variant <- [path | variants(path)] do
      conn = request(method, variant, key)

      assert conn.status in [403, 404],
             "#{method} #{variant} answered #{conn.status} to an analyze-only key"
    end
  end

  test "a malformed escape does not step around authentication" do
    assert request(:get, "/v1/cache/%zzstats").status == 401
    assert request(:get, "/%zz/../v1/cache/stats").status in [401, 404]
  end

  test "an encoded slash inside the Try It URL still reaches the public route" do
    # The landing page submits /url=<encodeURIComponent(repo)>. Deciding auth on
    # the decoded path must not start demanding credentials for a repo whose
    # URL happens to contain /v1.
    conn = request(:get, "/validate-url/url=https%3A%2F%2Fgithub.com%2Fexample%2Fv1")
    assert conn.status != 401
  end
end
