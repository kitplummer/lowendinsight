defmodule Lei.Acp.Auth do
  @moduledoc """
  ACP authentication plug: Bearer token and HMAC signature verification.

  ## An absent secret is a refusal, not a pass

  Both checks used to return `{:ok, conn}` -- authenticated -- when their
  secret was absent, commented "dev mode". `LEI_ACP_BEARER_TOKEN` and
  `LEI_ACP_SIGNING_SECRET` have never been set in production, so
  `POST /acp/checkout` and `/complete` were open to anyone for as long as they
  have existed. The only thing bounding that was the single SKU charging $29,
  which is a pricing accident rather than a control: the former `lei-free` SKU
  handed out a free-tier org to any caller.

  Unconfigured now refuses with the same opaque 503 the kill switch returns.
  What is missing is logged, never sent -- an anonymous caller should not be
  able to read our configuration state off the response.

  ## Why the opt-in is explicit rather than derived from the environment

  Local development still needs to call these routes without secrets, and that
  is `:acp_allow_unauthenticated`, set in `config/dev.exs` and
  `config/test.exs`.

  It would have been shorter to skip the checks unless
  `Lei.Stripe.Mode.production?/0`, and that is the wrong shape here: a deploy
  that loses `LEI_DEPLOY_ENV` would silently re-open the endpoint. That
  variable already downgrades `Lei.Stripe.ObjectCheck` from "unconfigured" to
  "ok" for the same reason, and one such dependency is enough. Refusing unless
  something explicitly says otherwise means a configuration that is merely
  absent fails closed.
  """
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    with :ok <- check_configured(),
         {:ok, conn} <- verify_bearer(conn),
         {:ok, conn} <- verify_hmac(conn) do
      conn
    else
      {:error, conn} -> conn
      {:unconfigured, missing} -> refuse_unconfigured(conn, missing)
    end
  end

  # Both secrets, or an explicit opt-in. Checked before either verification,
  # so half a configuration refuses rather than enforcing the half it has and
  # waving the other through.
  defp check_configured do
    if Application.get_env(:lei_service, :acp_allow_unauthenticated, false) == true do
      :ok
    else
      missing =
        [
          {:acp_bearer_token, "LEI_ACP_BEARER_TOKEN"},
          {:acp_signing_secret, "LEI_ACP_SIGNING_SECRET"}
        ]
        |> Enum.reject(fn {key, _env} ->
          case Application.get_env(:lei_service, key) do
            value when is_binary(value) -> value != ""
            _ -> false
          end
        end)
        |> Enum.map(fn {_key, env} -> env end)

      if missing == [], do: :ok, else: {:unconfigured, missing}
    end
  end

  defp refuse_unconfigured(conn, missing) do
    Logger.error(
      "ACP request refused: #{Enum.join(missing, " and ")} not set, so the request " <>
        "cannot be authenticated. Set them with 'flyctl secrets import', or set " <>
        ":acp_allow_unauthenticated for local development."
    )

    send_json(conn, 503, %{error: "checkout unavailable"})
  end

  defp verify_bearer(conn) do
    expected = Application.get_env(:lei_service, :acp_bearer_token)

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
    signing_secret = Application.get_env(:lei_service, :acp_signing_secret)

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
