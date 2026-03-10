defmodule LowendinsightGet.Auth do
  import Plug.Conn
  require Logger

  def init(opts) do
    opts
  end

  defp signer do
    secret = Application.get_env(:lowendinsight_get, :jwt_secret, "my super secret")
    Joken.Signer.create("HS256", secret)
  end

  defp authenticate({conn, "Bearer lei_" <> _rest = token}) do
    # Delegate lei_ API keys to Lei.Auth's key authentication
    raw_key = String.replace_prefix(token, "Bearer ", "")

    case Lei.ApiKeys.authenticate_key(raw_key) do
      {:ok, api_key} ->
        Lei.ApiKeys.touch_last_used(api_key)

        conn
        |> Plug.Conn.assign(:current_api_key, api_key)
        |> Plug.Conn.assign(:auth_method, :api_key)

      {:error, {:org_not_active, status}} ->
        send_401(conn, %{error: "organization not active", status: status})

      {:error, _} ->
        send_401(conn, %{error: "invalid API key"})
    end
  end

  defp authenticate({conn, "Bearer " <> jwt}) when jwt != "" do
    case Joken.verify(jwt, signer()) do
      {:ok, _} ->
        Logger.debug("Valid Token, proceed")
        conn

      {:error, err} ->
        send_401(conn, %{error: err})
    end
  end

  defp authenticate({conn, _invalid}) do
    send_401(conn)
  end

  defp authenticate({conn}) do
    send_401(conn)
  end

  defp send_401(
         conn,
         data \\ %{message: "Please make sure you have authentication header"}
       ) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Poison.encode!(data))
    |> halt
  end

  defp get_auth_header(conn) do
    case get_req_header(conn, "authorization") do
      [token] -> {conn, token}
      _ -> {conn}
    end
  end

  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    ## Only do auth on API bits
    case String.contains?(path, "/v1") do
      true ->
        conn
        |> get_auth_header
        |> authenticate

      _ ->
        conn
    end
  end
end

defmodule LowendinsightGet.Auth.Token do
  use Joken.Config
end
