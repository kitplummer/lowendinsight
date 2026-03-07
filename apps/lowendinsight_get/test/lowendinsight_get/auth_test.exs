defmodule LowendinsightGet.AuthTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias LowendinsightGet.Auth

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LowendinsightGet.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(LowendinsightGet.Repo, {:shared, self()})

    {:ok, org} = LowendinsightGet.ApiKeys.find_or_create_org("Auth Test Org")
    {:ok, raw_key, _api_key} = LowendinsightGet.ApiKeys.create_api_key(org, "auth-test-key")
    %{raw_key: raw_key}
  end

  test "accepts valid API key", %{raw_key: raw_key} do
    conn =
      conn(:get, "/v1/cache/stats")
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call(%{})

    assert conn.status != 401
    assert conn.assigns[:current_api_key] != nil
    assert conn.assigns[:auth_method] == :api_key
  end

  test "rejects invalid API key" do
    conn =
      conn(:get, "/v1/cache/stats")
      |> put_req_header("authorization", "Bearer lei_invalid_key_here_padding00")
      |> Auth.call(%{})

    assert conn.status == 401
    assert conn.halted
  end

  test "JWT still works" do
    secret = Application.get_env(:lowendinsight_get, :jwt_secret, "my super secret")
    signer = Joken.Signer.create("HS256", secret)
    {:ok, jwt, _claims} = Joken.generate_and_sign(%{}, %{}, signer)

    conn =
      conn(:get, "/v1/cache/stats")
      |> put_req_header("authorization", "Bearer #{jwt}")
      |> Auth.call(%{})

    assert conn.status != 401
    refute conn.halted
  end

  test "returns 401 with no auth header" do
    conn =
      conn(:get, "/v1/cache/stats")
      |> Auth.call(%{})

    assert conn.status == 401
    assert conn.halted
  end

  test "skips auth for non-v1 paths" do
    conn =
      conn(:get, "/")
      |> Auth.call(%{})

    refute conn.halted
  end
end
