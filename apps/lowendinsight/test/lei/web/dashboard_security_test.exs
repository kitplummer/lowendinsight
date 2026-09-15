defmodule Lei.Web.DashboardSecurityTest do
  @moduledoc """
  The HTML dashboard manages an org's keys, so it must only ever manage that
  org's keys, grant what an org may grant itself, and render what it stores as
  text.

  Found in the 2026-09-14 security review:
  - POST /keys/:key_id/revoke revoked whatever key id it was given, from any org
  - POST /keys granted any scope typed into the form, including `cache`
  - templates were rendered with plain EEx, so org and key names were written
    into the page as markup
  - the session cookie had no SameSite attribute, and a session outlived both
    the key that opened it and any reasonable age
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Lei.ApiKeys

  @opts Lei.Web.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()
    :ok
  end

  defp call(conn), do: Lei.Web.Router.call(conn, @opts)

  defp org(name \\ nil) do
    {:ok, org} =
      ApiKeys.create_org(name || "Dash Sec #{System.unique_integer([:positive])}",
        status: "active"
      )

    {:ok, raw, key} = ApiKeys.create_api_key(org, "admin", ["admin", "analyze"])
    %{org: org, raw: raw, key: key}
  end

  defp login(%{raw: raw}) do
    conn =
      conn(:post, "/login", "api_key=#{raw}")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> call()

    assert conn.status == 302
    conn |> get_resp_header("set-cookie") |> List.first()
  end

  defp form(cookie, path, body \\ "") do
    conn(:post, path, body)
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("cookie", cookie)
    |> call()
  end

  defp dashboard(cookie) do
    conn(:get, "/dashboard") |> put_req_header("cookie", cookie) |> call()
  end

  # A signed session cookie holding exactly `data`, as a browser would present it.
  defp session_with(data) do
    secret = Application.get_env(:lowendinsight, :session_secret_key_base)

    opts =
      Plug.Session.init(
        store: :cookie,
        key: "_lei_session",
        signing_salt: "lei_auth",
        secret_key_base: secret
      )

    conn(:get, "/dashboard")
    |> Map.put(:secret_key_base, secret)
    |> Plug.Session.call(opts)
    |> fetch_session()
    |> then(fn c -> Enum.reduce(data, c, fn {k, v}, acc -> put_session(acc, k, v) end) end)
  end

  defp active?(key_id), do: Lei.Repo.get!(Lei.ApiKey, key_id).active

  describe "revoking" do
    test "a key belonging to another org is not revoked" do
      mine = org()
      theirs = org()

      form(login(mine), "/keys/#{theirs.key.id}/revoke")

      assert active?(theirs.key.id)
    end

    test "a key belonging to the signed-in org is revoked" do
      mine = org()
      {:ok, _, spare} = ApiKeys.create_api_key(mine.org, "spare", ["analyze"])

      form(login(mine), "/keys/#{spare.id}/revoke")

      refute active?(spare.id)
    end
  end

  describe "creating" do
    test "a scope an org may not grant itself is refused" do
      mine = org()

      conn = form(login(mine), "/keys", "name=sneaky&scopes=analyze,cache")

      assert conn.resp_body =~ "cannot be granted"
      refute Enum.any?(ApiKeys.list_keys(mine.org), &("cache" in &1.scopes))
      assert length(ApiKeys.list_keys(mine.org)) == 1
    end

    test "self-service scopes are granted" do
      mine = org()

      form(login(mine), "/keys", "name=ci&scopes=analyze")

      assert Enum.any?(
               ApiKeys.list_keys(mine.org),
               &(&1.name == "ci" and &1.scopes == ["analyze"])
             )
    end
  end

  describe "rendering" do
    test "org and key names are rendered as text, not markup" do
      mine = org(~s|<script>alert("org")</script>|)

      {:ok, _, _} =
        ApiKeys.create_api_key(mine.org, ~s|<img src=x onerror=alert(1)>|, ["analyze"])

      body = dashboard(login(mine)).resp_body

      refute body =~ "<script>alert"
      refute body =~ "<img src=x"
      assert body =~ "&lt;script&gt;alert(&quot;org&quot;)&lt;/script&gt;"
      assert body =~ "&lt;img src=x onerror=alert(1)&gt;"
    end

    test "the page's own markup is not escaped" do
      body = dashboard(login(org())).resp_body

      assert body =~ "<table"
      assert body =~ ~s(<form method="post")
      refute body =~ "&lt;table"
    end
  end

  describe "the session" do
    test "the cookie is HttpOnly and SameSite=Lax" do
      cookie_header =
        conn(:post, "/login", "api_key=#{org().raw}")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> call()
        |> get_resp_header("set-cookie")
        |> List.first()

      assert cookie_header =~ ~r/HttpOnly/i
      assert cookie_header =~ ~r/SameSite=Lax/i
    end

    test "ends when the key that opened it is revoked" do
      mine = org()
      cookie = login(mine)
      assert dashboard(cookie).status == 200

      {:ok, _} = ApiKeys.revoke_key(mine.key.id)

      conn = dashboard(cookie)
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
    end

    test "a session with no signed-in key is not accepted" do
      # What every session looked like before: only an org slug, forever.
      mine = org()
      conn = session_with(%{"org_slug" => mine.org.slug})
      conn = Lei.Web.SessionAuth.call(conn, [])

      assert conn.halted
    end

    test "expires" do
      mine = org()
      old = System.system_time(:second) - Lei.Web.SessionAuth.max_age_seconds() - 1

      conn =
        session_with(%{
          "org_slug" => mine.org.slug,
          "api_key_id" => mine.key.id,
          "signed_in_at" => old
        })

      assert Lei.Web.SessionAuth.call(conn, []).halted
    end
  end
end
