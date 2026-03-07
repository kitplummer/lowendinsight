defmodule Lei.Auth do
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    if String.starts_with?(path, "/v1") do
      conn
      |> get_auth_header()
      |> authenticate()
    else
      conn
    end
  end

  defp get_auth_header(conn) do
    case get_req_header(conn, "authorization") do
      [token] -> {conn, token}
      _ -> {conn}
    end
  end

  defp authenticate({conn, "Bearer lei_" <> _rest = token}) do
    raw_key = String.replace_prefix(token, "Bearer ", "")

    case Lei.ApiKeys.authenticate_key(raw_key) do
      {:ok, api_key} ->
        Lei.ApiKeys.touch_last_used(api_key)
        conn |> assign(:current_api_key, api_key) |> assign(:auth_method, :api_key)

      {:error, _} ->
        send_401(conn, %{error: "invalid API key"})
    end
  end

  defp authenticate({conn, "Bearer " <> jwt}) do
    secret = Application.get_env(:lowendinsight, :jwt_secret, "lei_dev_secret")
    signer = Joken.Signer.create("HS256", secret)

    case Joken.verify(jwt, signer) do
      {:ok, _} ->
        Logger.debug("Valid JWT, proceed")
        conn

      {:error, err} ->
        send_401(conn, %{error: err})
    end
  end

  defp authenticate({conn}) do
    send_401(conn)
  end

  defp send_401(conn, data \\ %{message: "authentication required"}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Poison.encode!(data))
    |> halt()
  end
end
