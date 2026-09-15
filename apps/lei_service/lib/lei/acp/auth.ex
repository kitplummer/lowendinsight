defmodule Lei.Acp.Auth do
  @moduledoc """
  ACP authentication plug: Bearer token + optional HMAC signature verification.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, conn} <- verify_bearer(conn),
         {:ok, conn} <- verify_hmac(conn) do
      conn
    else
      {:error, conn} -> conn
    end
  end

  defp verify_bearer(conn) do
    expected = Application.get_env(:lowendinsight, :acp_bearer_token)

    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when not is_nil(expected) ->
        if byte_size(token) == byte_size(expected) and :crypto.hash_equals(token, expected) do
          {:ok, conn}
        else
          {:error, send_json(conn, 401, %{error: "invalid bearer token"})}
        end

      _ when is_nil(expected) ->
        # No bearer token configured; skip check (dev mode)
        {:ok, conn}

      _ ->
        {:error, send_json(conn, 401, %{error: "missing or invalid authorization header"})}
    end
  end

  defp verify_hmac(conn) do
    signing_secret = Application.get_env(:lowendinsight, :acp_signing_secret)

    case {signing_secret, get_req_header(conn, "x-acp-signature")} do
      {nil, _} ->
        # No signing secret configured; skip HMAC (dev mode)
        {:ok, conn}

      {_secret, []} ->
        # Signing secret configured but no signature header
        {:error, send_json(conn, 401, %{error: "missing x-acp-signature header"})}

      {secret, [signature]} ->
        raw_body = conn.private[:raw_body] || ""
        expected = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)

        if byte_size(expected) == byte_size(signature) and
             :crypto.hash_equals(expected, signature) do
          {:ok, conn}
        else
          {:error, send_json(conn, 401, %{error: "invalid HMAC signature"})}
        end
    end
  end

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Poison.encode!(data))
    |> halt()
  end
end
