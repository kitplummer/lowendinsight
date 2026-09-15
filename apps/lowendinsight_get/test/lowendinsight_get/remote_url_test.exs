defmodule LowendinsightGet.RemoteUrlTest do
  @moduledoc """
  The service clones only public repositories over https.

  `GET /url=` passed whatever it was given to the analyzer without validating
  it, and `Helpers.validate_url/1` -- used by /v1/analyze -- allows `file://`
  and any host that resolves, including loopback, cloud metadata and Fly's
  private network. So the service would `git clone` (or `git status` a local
  path) on a caller's behalf against addresses only it can reach.

  The library keeps `file://` for its command-line use; this is the rule for
  the web service (decided 2026-09-15: public https only).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias LowendinsightGet.RemoteUrl

  @opts LowendinsightGet.Endpoint.init([])

  # Resolution is a parameter so the address rules can be tested without DNS.
  defp resolving_to(addrs), do: fn _host -> {:ok, addrs} end

  describe "validate/2 refuses" do
    for {label, url} <- [
          {"a local path", "file:///etc"},
          {"plain http", "http://github.com/kitplummer/lowendinsight"},
          # Port 443 written out, so only the scheme rule refuses it: plain
          # http is otherwise also caught by the port rule, which left the
          # scheme rule untested (its guard came back unguarded).
          {"http on port 443", "http://github.com:443/kitplummer/lowendinsight"},
          {"git protocol", "git://github.com/kitplummer/lowendinsight"},
          {"credentials in the URL", "https://user:secret@github.com/kitplummer/lowendinsight"},
          {"a non-standard port", "https://github.com:8443/kitplummer/lowendinsight"},
          {"no host", "https:///kitplummer/lowendinsight"},
          {"not a URL", "github.com/kitplummer/lowendinsight"}
        ] do
      test label do
        assert {:error, _} =
                 RemoteUrl.validate(unquote(url), resolve: resolving_to([{140, 82, 112, 3}]))
      end
    end

    for {label, addr} <- [
          {"loopback", {127, 0, 0, 1}},
          {"cloud metadata (link-local)", {169, 254, 169, 254}},
          {"RFC 1918 10/8", {10, 1, 2, 3}},
          {"RFC 1918 172.16/12", {172, 20, 0, 1}},
          {"RFC 1918 192.168/16", {192, 168, 1, 1}},
          {"carrier-grade NAT", {100, 64, 0, 1}},
          {"unspecified", {0, 0, 0, 0}},
          {"multicast", {224, 0, 0, 1}},
          {"IPv6 loopback", {0, 0, 0, 0, 0, 0, 0, 1}},
          {"Fly private network (fdaa::/16, in fc00::/7)", {0xFDAA, 0, 0x33C6, 0, 0, 0, 0, 2}},
          {"IPv6 link-local", {0xFE80, 0, 0, 0, 0, 0, 0, 1}},
          {"IPv4-mapped loopback", {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}}
        ] do
      test "a host resolving to #{label}" do
        assert {:error, _} =
                 RemoteUrl.validate("https://evil.example/owner/repo",
                   resolve: resolving_to([unquote(Macro.escape(addr))])
                 )
      end
    end

    test "a host with any private address among public ones" do
      assert {:error, _} =
               RemoteUrl.validate("https://evil.example/owner/repo",
                 resolve: resolving_to([{140, 82, 112, 3}, {127, 0, 0, 1}])
               )
    end

    test "a host that does not resolve" do
      assert {:error, _} =
               RemoteUrl.validate("https://evil.example/owner/repo",
                 resolve: fn _ -> {:error, :nxdomain} end
               )
    end

    test "an IP literal in a private range, with real resolution" do
      assert {:error, _} = RemoteUrl.validate("https://169.254.169.254/latest/meta-data")
      assert {:error, _} = RemoteUrl.validate("https://[::1]/owner/repo")
      assert {:error, _} = RemoteUrl.validate("https://localhost/owner/repo")
    end
  end

  describe "validate/2 accepts" do
    test "https to a public address" do
      assert :ok =
               RemoteUrl.validate("https://github.com/kitplummer/lowendinsight",
                 resolve: resolving_to([{140, 82, 112, 3}, {0x2606, 0x50C0, 0, 0, 0, 0, 0, 1}])
               )
    end

    test "https on the default port written out" do
      assert :ok =
               RemoteUrl.validate("https://gitlab.com:443/owner/repo",
                 resolve: resolving_to([{172, 65, 251, 78}])
               )
    end
  end

  describe "through the service" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
      Lei.RateLimiter.clear()
      LowendinsightGet.Plugs.RateLimiter.clear()
      :ok
    end

    test "Try It refuses a local path before any analysis" do
      # Cleared first: run against the unfixed route, this test analysed /etc
      # and cached the result, which is the bug.
      LowendinsightGet.Datastore.delete_from_cache("file:///etc")

      conn = conn(:get, "/url=" <> URI.encode_www_form("file:///etc")) |> call()

      assert conn.status == 400
      refute LowendinsightGet.Datastore.in_cache?("file:///etc")
    end

    test "Try It refuses the metadata address" do
      conn =
        conn(:get, "/url=" <> URI.encode_www_form("https://169.254.169.254/latest")) |> call()

      assert conn.status == 400
    end

    test "the form's pre-check agrees" do
      conn =
        conn(:get, "/validate-url/url=" <> URI.encode_www_form("file:///etc")) |> call()

      refute conn.status == 200
    end

    test "/v1/analyze refuses a private address" do
      {:ok, org} =
        Lei.ApiKeys.create_org("Remote Url #{System.unique_integer([:positive])}",
          tier: "pro",
          status: "active"
        )

      {:ok, key, _} = Lei.ApiKeys.create_api_key(org, "t", ["analyze"])

      conn =
        conn(:post, "/v1/analyze", %{"urls" => ["https://127.0.0.1/owner/repo"]})
        |> put_req_header("authorization", "Bearer " <> key)
        |> call()

      assert conn.status == 422
    end

    test "the analysis entry point refuses what the routes would" do
      assert {:error, _} =
               LowendinsightGet.Analysis.analyze("file:///etc", "lei-get", %{types: false})
    end
  end

  defp call(conn), do: LowendinsightGet.Endpoint.call(conn, @opts)
end
