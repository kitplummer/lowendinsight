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

  # An agent paying with MPP puts its credential in Authorization under the
  # Payment scheme. It fell through to the clause below, so every paying retry
  # was answered 401 before Lei.Payments ever saw it -- in production, while
  # every test of the payment path passed against Lei.Web.Router (#147).
  # Verification happens in Lei.Payments.Gate; this only lets it get there.
  defp authenticate({conn, "Payment " <> _credential}) do
    if Lei.Payments.Gate.paid_route?(conn),
      do: Plug.Conn.assign(conn, :auth_method, :payment),
      else: send_401(conn)
  end

  defp authenticate({conn, _invalid}) do
    send_401(conn)
  end

  # No credentials on a paid route is an agent that has never been here. It is
  # asked to pay, by the gate, rather than told to authenticate with something
  # it cannot have. Everywhere else is unchanged.
  defp authenticate({conn}) do
    if Lei.Payments.Gate.paid_route?(conn),
      do: Plug.Conn.assign(conn, :auth_method, :anonymous),
      else: send_401(conn)
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

      # starts_with on the canonical path, not contains: a decoded Try It URL
      # such as /url=https://github.com/x/v1 contains "/v1" and is public.
      String.starts_with?(path, "/v1") ->
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
  # the routes it does not, including "or admin", so an admin key still works
  # everywhere.
  @scope_prefixes [{"/v1/cache", "cache"}]

  defp check_scope(%Plug.Conn{halted: true} = conn, _path), do: conn

  defp check_scope(conn, path) do
    case required_scope(path) do
      nil ->
        conn

      required ->
        # A JWT is signed with the deployment's own secret, so holding one is
        # already operator-level. API keys are handed out to customers, and an
        # analyze-scoped key must not be able to read or rewrite the cache.
        if conn.assigns[:auth_method] == :jwt or has_scope?(conn, required) do
          conn
        else
          Logger.warning("#{path} requested without #{required} scope")

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(403, Poison.encode!(%{error: "insufficient scope", required: required}))
          |> halt()
        end
    end
  end

  defp required_scope(path) do
    Enum.find_value(@scope_prefixes, fn {prefix, scope} ->
      if String.starts_with?(path, prefix), do: scope
    end)
  end

  # A narrow scope, or admin. The canary needs only to invalidate a cache
  # entry, and issuing it an admin key to do that would also let it create
  # orgs and mint further keys -- more authority in a CI secret than the job
  # requires.
  defp has_scope?(conn, required) do
    case conn.assigns[:current_api_key] do
      # The scope itself, and nothing broader. "admin" was accepted here too,
      # and every signup key is admin of its own org -- so any stranger could
      # export, import over or invalidate the cache everyone is served
      # (security, 2026-09-14). Operators use a JWT.
      %{scopes: scopes} when is_list(scopes) -> required in scopes
      _ -> false
    end
  end
end

defmodule LowendinsightGet.Auth.Token do
  use Joken.Config
end
