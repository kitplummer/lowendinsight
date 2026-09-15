defmodule Lei.Auth do
  import Plug.Conn
  require Logger

  @scope_map %{
    {"/v1/analyze", "POST"} => "analyze",
    {"/v1/analyze/batch", "POST"} => "analyze",
    {"/v1/usage", "GET"} => "analyze",
    {"/v1/health", "GET"} => nil,
    {"/v1/orgs", "POST"} => "admin",
    {"/v1/orgs", "GET"} => "admin"
  }

  def init(opts), do: opts

  @public_v1_paths ["/v1/health"]

  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    cond do
      path in @public_v1_paths ->
        conn

      String.starts_with?(path, "/v1") ->
        conn
        |> get_auth_header()
        |> authenticate()
        |> check_scope()
        |> check_rate_limit()

      true ->
        conn
    end
  end

  defp get_auth_header(conn) do
    case get_req_header(conn, "authorization") do
      [token] -> {conn, token}
      _ -> {conn}
    end
  end

  # An agent paying with MPP puts its credential in Authorization, per the
  # Payment auth scheme. It is not a bearer token and there is no key to look
  # up -- the payment is how the caller identifies itself, and the org comes
  # from the challenge that payment answers.
  #
  # Passed through unauthenticated rather than rejected: without this clause
  # the scheme falls off the end of authenticate/1 and a paying agent gets a
  # 500 for presenting a valid credential.
  defp authenticate({conn, "Payment " <> _credential}) do
    if Lei.Payments.Gate.paid_route?(conn),
      do: assign(conn, :auth_method, :payment),
      else: send_401(conn)
  end

  defp authenticate({conn, "Bearer lei_" <> _rest = token}) do
    # Skip re-auth if upstream plug already authenticated this key
    if conn.assigns[:current_api_key] do
      conn
    else
      raw_key = String.replace_prefix(token, "Bearer ", "")

      case Lei.ApiKeys.authenticate_key(raw_key) do
        {:ok, api_key} ->
          Lei.ApiKeys.touch_last_used(api_key)
          conn |> assign(:current_api_key, api_key) |> assign(:auth_method, :api_key)

        {:error, {:org_not_active, status}} ->
          send_403(conn, %{error: "organization not active", status: status})

        {:error, _} ->
          send_401(conn, %{error: "invalid API key"})
      end
    end
  end

  defp authenticate({conn, "Bearer " <> jwt}) do
    secret = Application.get_env(:lowendinsight, :jwt_secret, "lei_dev_secret")
    signer = Joken.Signer.create("HS256", secret)

    case Joken.verify(jwt, signer) do
      {:ok, _} ->
        Logger.debug("Valid JWT, proceed")
        # Marked, as LeiService.Auth marks it. Lei.Payments.Gate serves an
        # unkeyed request unbilled only when it carries an operator token, and
        # treats an unmarked one as a caller to be asked to pay.
        assign(conn, :auth_method, :jwt)

      {:error, err} ->
        send_401(conn, %{error: err})
    end
  end

  # A paid route with no credentials is an agent to be asked to pay, not told
  # to authenticate (#147). Lei.Payments.Gate makes that decision, and refuses
  # by default.
  defp authenticate({conn}) do
    if Lei.Payments.Gate.paid_route?(conn),
      do: assign(conn, :auth_method, :anonymous),
      else: send_401(conn)
  end

  defp check_scope(%Plug.Conn{halted: true} = conn), do: conn

  defp check_scope(conn) do
    required = required_scope(conn)

    cond do
      is_nil(required) ->
        conn

      conn.assigns[:auth_method] != :api_key ->
        conn

      true ->
        scopes = conn.assigns[:current_api_key].scopes

        if required in scopes or "admin" in scopes do
          conn
        else
          send_403(conn, %{error: "insufficient scope", required: required})
        end
    end
  end

  defp check_rate_limit(%Plug.Conn{halted: true} = conn), do: conn

  defp check_rate_limit(conn) do
    if conn.assigns[:auth_method] == :api_key do
      api_key = conn.assigns[:current_api_key]
      tier = api_key.org.tier

      case Lei.RateLimiter.check(api_key.key_prefix, tier) do
        {:ok, remaining} ->
          conn
          |> put_resp_header("x-ratelimit-remaining", to_string(remaining))

        {:error, :rate_limited, retry_after} ->
          retry_secs = div(retry_after, 1000) + 1

          conn
          |> put_resp_header("retry-after", to_string(retry_secs))
          |> put_resp_content_type("application/json")
          |> send_resp(
            429,
            Poison.encode!(%{error: "rate limit exceeded", retry_after: retry_secs})
          )
          |> halt()
      end
    else
      conn
    end
  end

  defp required_scope(conn) do
    Enum.find_value(@scope_map, fn {{prefix, method}, scope} ->
      if String.starts_with?(conn.request_path, prefix) and conn.method == method do
        scope
      end
    end)
  end

  defp send_401(conn, data \\ %{message: "authentication required"}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Poison.encode!(data))
    |> halt()
  end

  defp send_403(conn, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Poison.encode!(data))
    |> halt()
  end
end
