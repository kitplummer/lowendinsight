defmodule Lei.Web.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts Lei.Web.Router.init([])

  setup do
    Lei.BatchCache.clear()
    Lei.RateLimiter.clear()

    secret = Application.get_env(:lowendinsight, :jwt_secret, "lei_dev_secret")
    signer = Joken.Signer.create("HS256", secret)
    {:ok, jwt, _} = Joken.generate_and_sign(%{}, %{}, signer)
    %{token: jwt}
  end

  test "POST /v1/analyze/batch with valid dependencies", %{token: token} do
    body = %{
      "dependencies" => [
        %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"}
      ]
    }

    conn =
      conn(:post, "/v1/analyze/batch", Poison.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 200
    response = Poison.decode!(conn.resp_body)
    assert response["summary"]["total"] == 1
    assert is_binary(response["analyzed_at"])
  end

  test "POST /v1/analyze/batch with missing dependencies returns 400", %{token: token} do
    conn =
      conn(:post, "/v1/analyze/batch", Poison.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 400
    response = Poison.decode!(conn.resp_body)
    assert response["error"] =~ "missing required field"
  end

  test "POST /v1/analyze/batch with non-list dependencies returns 400", %{token: token} do
    body = %{"dependencies" => "not-a-list"}

    conn =
      conn(:post, "/v1/analyze/batch", Poison.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 400
    response = Poison.decode!(conn.resp_body)
    assert response["error"] =~ "must be an array"
  end

  test "POST /v1/analyze/batch with non-map dependency element returns 400", %{token: token} do
    body = %{
      "dependencies" => ["just a string", 42]
    }

    conn =
      conn(:post, "/v1/analyze/batch", Poison.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 400
    response = Poison.decode!(conn.resp_body)
    assert response["error"] =~ "ecosystem, package, and version"
  end

  test "POST /v1/analyze/batch with invalid dependency format returns 400", %{token: token} do
    body = %{
      "dependencies" => [
        %{"ecosystem" => "npm"}
      ]
    }

    conn =
      conn(:post, "/v1/analyze/batch", Poison.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 400
    response = Poison.decode!(conn.resp_body)
    assert response["error"] =~ "ecosystem, package, and version"
  end

  test "POST /v1/analyze/batch with empty dependencies returns 400", %{token: token} do
    body = %{"dependencies" => []}

    conn =
      conn(:post, "/v1/analyze/batch", Poison.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 400
  end

  test "GET /v1/health returns ok", %{token: token} do
    conn =
      conn(:get, "/v1/health")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 200
    response = Poison.decode!(conn.resp_body)
    assert response["status"] == "ok"
  end

  test "unknown route returns 404" do
    conn =
      conn(:get, "/nonexistent")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 404
  end

  test "X-Request-ID header is present and is a valid UUID", %{token: token} do
    conn =
      conn(:get, "/v1/health")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Lei.Web.Router.call(@opts)

    request_id = get_resp_header(conn, "x-request-id") |> List.first()
    assert request_id != nil
    assert {:ok, _} = Ecto.UUID.cast(request_id)
  end

  test "X-Request-ID echoes client-supplied header when valid UUID", %{token: token} do
    supplied_id = Ecto.UUID.generate()

    conn =
      conn(:get, "/v1/health")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("x-request-id", supplied_id)
      |> Lei.Web.Router.call(@opts)

    assert get_resp_header(conn, "x-request-id") == [supplied_id]
  end
end
