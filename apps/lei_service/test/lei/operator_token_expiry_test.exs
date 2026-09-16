defmodule Lei.OperatorTokenExpiryTest do
  @moduledoc """
  An operator token stops working when it expires.

  Both authentication paths called `Joken.verify/2`, which checks the
  signature and nothing else: a token whose `exp` had passed was accepted,
  and a token minted without `exp` was valid forever. An operator token is
  the credential that reaches every unbilled and operator-only route
  (security review, 2026-09-14).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @opts Lei.Web.Router.init([])
  @service_opts LeiService.Endpoint.init([])

  defp signer do
    Joken.Signer.create("HS256", Application.get_env(:lei_service, :jwt_secret, "lei_dev_secret"))
  end

  defp token(claims) do
    {:ok, jwt, _} = Joken.generate_and_sign(%{}, claims, signer())
    jwt
  end

  defp seconds_from_now(offset),
    do: DateTime.utc_now() |> DateTime.add(offset) |> DateTime.to_unix()

  defp operator_request(router, opts, jwt) do
    conn(:get, "/v1/gh_trending/elixir")
    |> put_req_header("authorization", "Bearer #{jwt}")
    |> router.call(opts)
  end

  for {name, router, opts} <- [
        {"Lei.Web.Router", Lei.Web.Router, @opts},
        {"LeiService.Endpoint", LeiService.Endpoint, @service_opts}
      ] do
    test "#{name}: a token that has expired is refused" do
      conn =
        operator_request(
          unquote(router),
          unquote(Macro.escape(opts)),
          token(%{"exp" => seconds_from_now(-60)})
        )

      assert conn.status == 401
    end

    test "#{name}: a token with no expiry is refused" do
      conn = operator_request(unquote(router), unquote(Macro.escape(opts)), token(%{}))
      assert conn.status == 401
    end

    test "#{name}: a token that is still valid is accepted" do
      conn =
        operator_request(
          unquote(router),
          unquote(Macro.escape(opts)),
          token(%{"exp" => seconds_from_now(3600)})
        )

      refute conn.status == 401
    end

    test "#{name}: a token signed with another secret is refused" do
      other = Joken.Signer.create("HS256", "not-the-deployment-secret")
      {:ok, jwt, _} = Joken.generate_and_sign(%{}, %{"exp" => seconds_from_now(3600)}, other)
      assert operator_request(unquote(router), unquote(Macro.escape(opts)), jwt).status == 401
    end
  end

  test "an expiry further out than the maximum lifetime is refused" do
    # A token minted with exp years away is the same forever-credential the
    # missing check allowed; the ceiling is what makes expiry mean something.
    max_seconds = Application.get_env(:lei_service, :operator_token_max_lifetime_seconds, 86_400)
    jwt = token(%{"exp" => seconds_from_now(max_seconds + 3600)})
    assert operator_request(Lei.Web.Router, @opts, jwt).status == 401
  end
end
