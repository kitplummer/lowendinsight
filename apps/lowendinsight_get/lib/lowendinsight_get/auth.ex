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
        # Marked explicitly so the scope check can tell a signed operator token
        # apart from an API key, rather than inferring it from the absence of
        # an assign -- which would also be true of a request that was never
        # authenticated at all.
        Plug.Conn.assign(conn, :auth_method, :jwt)

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

  # Health endpoints live under /v1 but must answer unauthenticated so that
  # platform probes (Fly http_checks, Kubernetes liveness/readiness) can reach
  # them. Lei.Auth keeps the same allowlist for the inner router.
  @public_v1_paths ["/v1/health"]

  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    ## Only do auth on API bits
    cond do
      path in @public_v1_paths ->
        conn

      String.contains?(path, "/v1") ->
        conn
        |> get_auth_header
        |> authenticate
        |> check_scope(path)

      true ->
        conn
    end
  end

  # Routes served by this endpoint rather than forwarded to Lei.Web.Router did
  # not have their scopes checked at all -- this plug authenticated and stopped
  # there, and none of the handlers checked either. Any key that could call the
  # API could export the whole cache, or import over it and change the answers
  # everyone else gets.
  #
  # Lei.Auth enforces scopes for the routes it owns; this is the same rule for
  # the routes it does not.
  @admin_prefixes ["/v1/cache"]

  defp check_scope(%Plug.Conn{halted: true} = conn, _path), do: conn

  defp check_scope(conn, path) do
    if Enum.any?(@admin_prefixes, &String.starts_with?(path, &1)) do
      # A JWT is signed with the deployment's own secret, so holding one is
      # already operator-level. API keys are handed out to customers, and an
      # analyze-scoped key must not be able to read or rewrite the cache.
      if conn.assigns[:auth_method] == :jwt or admin_key?(conn) do
        conn
      else
        Logger.warning("#{path} requested without admin scope")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Poison.encode!(%{error: "insufficient scope", required: "admin"}))
        |> halt()
      end
    else
      conn
    end
  end

  defp admin_key?(conn) do
    case conn.assigns[:current_api_key] do
      %{scopes: scopes} when is_list(scopes) -> "admin" in scopes
      _ -> false
    end
  end
end

defmodule LowendinsightGet.Auth.Token do
  use Joken.Config
end
