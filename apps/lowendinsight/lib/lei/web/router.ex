defmodule Lei.Web.Router do
  @moduledoc """
  HTTP router for LEI batch analysis API and web UI.

  Provides the POST /v1/analyze/batch endpoint for analyzing
  lists of dependencies with parallel cache lookups, plus
  HTML signup/login/dashboard routes.
  """
  use Plug.Router
  require Logger

  @otp_app :lowendinsight

  # Also served standalone on port 4000, so it cannot rely on the endpoint
  # having canonicalised the path. Idempotent when it has.
  plug(Lei.Plugs.CanonicalPath)
  plug(Plug.Logger)

  plug(:put_secret_key_base)

  plug(Plug.Session,
    store: :cookie,
    key: "_lei_session",
    signing_salt: "lei_auth"
  )

  plug(Plug.Static,
    at: "/static",
    from: {:lowendinsight, "priv/static"}
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :json],
    json_decoder: Poison,
    body_reader: {Lei.Acp.RawBodyReader, :read_body, []}
  )

  plug(Lei.Auth)
  plug(:match)
  plug(:dispatch)

  # --- HTML UI routes ---

  get "/signup" do
    render_page(conn, "signup.html.eex")
  end

  post "/signup" do
    name = conn.body_params["name"]
    tier = conn.body_params["tier"] || "free"

    if is_nil(name) or name == "" do
      render_page(conn, "signup.html.eex", flash_error: "Organization name is required.")
    else
      case tier do
        "free" -> signup_free(conn, name)
        "pro" -> signup_pro(conn, name)
        _ -> render_page(conn, "signup.html.eex", flash_error: "Invalid tier selected.")
      end
    end
  end

  get "/signup/success" do
    # Plug.Session only configures the store; the session must be fetched before
    # get_session/2, or it raises ArgumentError. Stripe sends the customer here
    # immediately after payment, so the raise surfaced as a 500 on the one page
    # a paying customer is guaranteed to see.
    conn = fetch_session(conn)
    org_id = get_session(conn, "pending_org_id")

    # Arriving here proves nothing: the URL can be requested without ever
    # visiting Stripe. Payment is confirmed with Stripe itself (Lei.Signup).
    with {:org, %Lei.Org{} = org} <- {:org, org_id && Lei.Repo.get(Lei.Org, org_id)},
         {:ok, org} <- Lei.Signup.confirm_paid_checkout(org, conn.params["session_id"]),
         {:ok, {org, raw_key, recovery_code}} <- Lei.Signup.issue_first_credentials(org) do
      conn
      |> delete_session("pending_org_id")
      |> render_page("signup_success.html.eex",
        org_name: org.name,
        raw_key: raw_key,
        recovery_code: recovery_code
      )
    else
      {:org, _} ->
        render_page(conn, "signup.html.eex",
          flash_error: "No pending signup found. Please try again."
        )

      {:error, :already_issued} ->
        conn
        |> delete_session("pending_org_id")
        |> render_page("login.html.eex",
          flash_error:
            "Credentials for this organization were already issued. Log in with your API key, or use your recovery code."
        )

      {:error, :suspended} ->
        render_page(conn, "signup.html.eex",
          flash_error: "This organization is suspended. Contact support to reactivate it."
        )

      {:error, reason} ->
        Logger.info("signup success not confirmed: #{inspect(reason)}")

        render_page(conn, "signup.html.eex",
          flash_error:
            "We could not confirm your payment yet. If you completed checkout, refresh this page in a minute."
        )
    end
  end

  get "/login" do
    render_page(conn, "login.html.eex")
  end

  post "/login" do
    raw_key = conn.body_params["api_key"]

    if is_nil(raw_key) or raw_key == "" do
      render_page(conn, "login.html.eex", flash_error: "API key is required.")
    else
      case Lei.ApiKeys.authenticate_key(raw_key) do
        {:ok, api_key} ->
          if "admin" in api_key.scopes do
            conn
            |> fetch_session()
            |> put_session("org_slug", api_key.org.slug)
            |> put_resp_header("location", "/dashboard")
            |> send_resp(302, "")
          else
            render_page(conn, "login.html.eex",
              flash_error: "This key does not have admin scope. Login requires an admin key."
            )
          end

        {:error, _} ->
          render_page(conn, "login.html.eex", flash_error: "Invalid API key.")
      end
    end
  end

  get "/dashboard" do
    conn = Lei.Web.SessionAuth.call(conn, [])

    if conn.halted do
      conn
    else
      org = conn.assigns[:current_org]
      keys = Lei.ApiKeys.list_keys(org)
      new_key = get_session(conn, "new_key")

      conn =
        if new_key do
          delete_session(conn, "new_key")
        else
          conn
        end

      render_page(conn, "dashboard.html.eex", org: org, keys: keys, new_key: new_key)
    end
  end

  post "/keys" do
    conn = Lei.Web.SessionAuth.call(conn, [])

    if conn.halted do
      conn
    else
      org = conn.assigns[:current_org]
      name = conn.body_params["name"] || "default"

      scopes =
        case conn.body_params["scopes"] do
          nil -> []
          "" -> []
          s -> s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.filter(&(&1 != ""))
        end

      case Lei.ApiKeys.create_api_key(org, name, scopes) do
        {:ok, raw_key, _api_key} ->
          keys = Lei.ApiKeys.list_keys(org)
          render_page(conn, "dashboard.html.eex", org: org, keys: keys, new_key: raw_key)

        {:error, _changeset} ->
          keys = Lei.ApiKeys.list_keys(org)

          render_page(conn, "dashboard.html.eex",
            org: org,
            keys: keys,
            flash_error: "Failed to create key."
          )
      end
    end
  end

  post "/keys/:key_id/revoke" do
    conn = Lei.Web.SessionAuth.call(conn, [])

    if conn.halted do
      conn
    else
      org = conn.assigns[:current_org]
      Lei.ApiKeys.revoke_key(key_id)
      keys = Lei.ApiKeys.list_keys(org)
      render_page(conn, "dashboard.html.eex", org: org, keys: keys, flash_info: "Key revoked.")
    end
  end

  get "/recover" do
    render_page(conn, "recover.html.eex")
  end

  post "/recover" do
    slug = conn.body_params["slug"]
    recovery_code = conn.body_params["recovery_code"]

    if is_nil(slug) or slug == "" or is_nil(recovery_code) or recovery_code == "" do
      render_page(conn, "recover.html.eex",
        flash_error: "Organization slug and recovery code are required."
      )
    else
      case Lei.ApiKeys.recover_with_code(slug, recovery_code) do
        {:ok, raw_key, new_recovery_code} ->
          render_page(conn, "recover_success.html.eex",
            raw_key: raw_key,
            recovery_code: new_recovery_code
          )

        {:error, :invalid_recovery} ->
          render_page(conn, "recover.html.eex", flash_error: "Invalid slug or recovery code.")
      end
    end
  end

  get "/logout" do
    conn
    |> fetch_session()
    |> clear_session()
    |> put_resp_header("location", "/login")
    |> send_resp(302, "")
  end

  # --- Stripe webhook ---

  post "/webhooks/stripe" do
    raw_body = conn.private[:raw_body] || ""
    signature = List.first(Plug.Conn.get_req_header(conn, "stripe-signature")) || ""
    webhook_secret = Application.get_env(:lowendinsight, :stripe_webhook_secret, "")
    stripe = Lei.Stripe.impl()

    # A wrong signing secret fails exactly like an unset one, and both fail
    # exactly like a scanner POSTing junk at a public URL. Separating them is
    # the difference between an alert worth waking up for and noise: only a
    # request Stripe actually signed can indicate a secret problem.
    cond do
      signature == "" ->
        Lei.WebhookStats.record(:unsigned)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Poison.encode!(%{error: "missing stripe-signature header"}))

      webhook_secret in [nil, ""] ->
        Lei.WebhookStats.record(:unconfigured)

        Logger.error(
          "Stripe signed a webhook but STRIPE_WEBHOOK_SECRET is not set. " <>
            "Every delivery will 400 until it is."
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Poison.encode!(%{error: "webhook secret not configured"}))

      true ->
        case stripe.construct_webhook_event(raw_body, signature, webhook_secret) do
          {:ok, event} ->
            Lei.WebhookStats.record(:ok)
            Lei.StripeWebhookHandler.handle_event(event)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Poison.encode!(%{status: "ok"}))

          {:error, reason} ->
            Lei.WebhookStats.record(:invalid)

            # The secret is set and disagrees with Stripe's signature. Almost
            # always a rotation that updated the endpoint but not the app, or
            # updated it from a different endpoint's secret.
            Logger.error(
              "Stripe webhook signature rejected (#{inspect(reason)}). " <>
                "STRIPE_WEBHOOK_SECRET is set but does not match the sending endpoint."
            )

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Poison.encode!(%{error: "invalid webhook signature"}))
        end
    end
  end

  # --- JSON API routes ---

  post "/v1/analyze/batch" do
    # A payment presented on the request is honoured before the quota is
    # checked, so a caller that was refused with a 402 gets served when it
    # retries the same request with a credential. There is no separate endpoint
    # to pay at, which is what lets an agent that has never been here before
    # get from refusal to result on its own.
    conn = Lei.Payments.Gate.settle(conn)

    case validate_batch_request(conn.body_params) do
      {:ok, dependencies, opts} ->
        # Refusals -- free tier exhausted, credits exhausted, or no org at all --
        # are sent by the gate, with payment challenges where one applies.
        case Lei.Payments.Gate.admit(conn) do
          {:halt, conn} ->
            conn

          {:ok, conn, {org_id, api_key_id, tier}} ->
            result = Lei.BatchAnalyzer.analyze(dependencies, opts)
            cached = result.summary.cached
            pending = result.summary.pending

            if org_id do
              Lei.UsageTracker.record_usage_async(org_id, api_key_id, cached, pending)
            end

            cost = Lei.UsageTracker.calculate_cost(cached, pending)

            enriched =
              Map.put(result, :billing, %{
                cache_hits: cached,
                cache_misses: pending,
                cost_cents: Decimal.to_float(cost),
                tier: tier || "unknown"
              })

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Poison.encode!(enriched))
        end

      {:error, message} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Poison.encode!(%{error: message}))
    end
  end

  get "/v1/credits" do
    # Scoped to the authenticated org by construction: org_id comes from the
    # API key, never from a parameter. There is no way to ask for another org's
    # ledger through this route, which is the point -- a balance is money.
    case Lei.Payments.Gate.billing_context(conn) do
      {nil, _, _} ->
        json_resp(conn, 401, %{error: "API key required for credits endpoint"})

      {org_id, _, _tier} ->
        entries =
          org_id
          |> Lei.Credits.entries(limit: 50)
          |> Enum.map(fn entry ->
            %{
              delta: entry.delta,
              reason: entry.reason,
              # external_ref is deliberately omitted: it is a Stripe payment
              # intent or an on-chain transaction hash, and the balance does
              # not need it to be explicable.
              at: NaiveDateTime.to_iso8601(entry.inserted_at)
            }
          end)

        json_resp(conn, 200, %{
          balance: Lei.Credits.balance(org_id),
          # Stated rather than assumed by the caller. One credit is $0.001.
          credit_value_usd: "0.001",
          pricing: %{
            cache_hit: Lei.Credits.credits_per_cache_hit(),
            cache_miss: Lei.Credits.credits_per_cache_miss()
          },
          entries: entries
        })
    end
  end

  get "/v1/usage" do
    case Lei.Payments.Gate.billing_context(conn) do
      {nil, _, _} ->
        json_resp(conn, 401, %{error: "API key required for usage endpoint"})

      {org_id, _, tier} ->
        usage = Lei.UsageTracker.get_current_usage(org_id)
        pro_credit = Application.get_env(:lowendinsight, :pro_tier_credit_cents, 1500)

        included_credit =
          if tier == "pro", do: pro_credit, else: 0

        overage =
          if tier == "pro" do
            ov = Decimal.sub(usage.total_cost_cents, Decimal.new("#{included_credit}"))
            Decimal.max(ov, Decimal.new(0))
          else
            Decimal.new(0)
          end

        json_resp(conn, 200, %{
          period_start: Date.to_iso8601(usage.period_start),
          cache_hits: usage.cache_hits,
          cache_misses: usage.cache_misses,
          total_cost_cents: Decimal.to_float(usage.total_cost_cents),
          tier: tier,
          included_credit_cents: included_credit,
          overage_cents: Decimal.to_float(overage)
        })
    end
  end

  get "/v1/health" do
    Lei.Web.Controllers.HealthController.get(conn)
  end

  # --- Self-registration endpoints ---

  post "/v1/orgs" do
    # Creating orgs is an operator action. It required only the "admin" scope,
    # which every signup key carries.
    case {conn.assigns[:auth_method], conn.body_params} do
      {method, _} when method != :jwt ->
        json_resp(conn, 403, %{error: "operator credentials required"})

      {_, body_params} ->
        create_org_from(conn, body_params)
    end
  end

  defp create_org_from(conn, body_params) do
    case body_params do
      %{"name" => name} when is_binary(name) and name != "" ->
        # find_or_create_org/2 is correct here, unlike on the signup paths: this
        # route requires the "admin" scope and returns only org metadata, never
        # a key. Idempotent creation is intended -- see the registration test.
        case Lei.ApiKeys.find_or_create_org(name) do
          {:ok, org} ->
            json_resp(conn, 201, %{
              id: org.id,
              name: org.name,
              slug: org.slug,
              tier: org.tier
            })

          {:error, changeset} ->
            json_resp(conn, 422, %{error: format_errors(changeset)})
        end

      _ ->
        json_resp(conn, 400, %{error: "missing required field: name"})
    end
  end

  # --- Org key management ---
  #
  # An org's credentials act on that org only (security, 2026-09-14). Signup
  # gives every org a key with the "admin" scope -- admin *of that org*. These
  # routes checked neither ownership nor who was asking, so any stranger's
  # signup key could mint a key for any org and take it over, list its keys,
  # or revoke them. A slug the caller may not manage answers exactly like one
  # that does not exist, so slugs cannot be enumerated.

  post "/v1/orgs/:slug/keys" do
    with {:ok, org} <- authorize_org(conn, slug),
         scopes = get_in(conn.body_params, ["scopes"]) || [],
         :ok <- authorize_scopes(conn, scopes) do
      name = get_in(conn.body_params, ["name"]) || "default"

      case Lei.ApiKeys.create_api_key(org, name, scopes) do
        {:ok, raw_key, api_key} ->
          json_resp(conn, 201, %{
            key: raw_key,
            name: api_key.name,
            key_prefix: api_key.key_prefix,
            scopes: api_key.scopes,
            warning: "Store this key securely. It will not be shown again."
          })

        {:error, changeset} ->
          json_resp(conn, 422, %{error: format_errors(changeset)})
      end
    else
      {:error, status, body} -> json_resp(conn, status, body)
    end
  end

  get "/v1/orgs/:slug/keys" do
    case authorize_org(conn, slug) do
      {:ok, org} ->
        keys = Lei.ApiKeys.list_keys(org)

        json_resp(conn, 200, %{
          keys:
            Enum.map(keys, fn k ->
              %{
                id: k.id,
                name: k.name,
                key_prefix: k.key_prefix,
                scopes: k.scopes,
                active: k.active,
                last_used_at: k.last_used_at
              }
            end)
        })

      {:error, status, body} ->
        json_resp(conn, status, body)
    end
  end

  delete "/v1/orgs/:slug/keys/:key_id" do
    with {:ok, org} <- authorize_org(conn, slug),
         # The key must belong to the org in the path. It was looked up by id
         # alone, so any org's key could be revoked through any slug.
         %Lei.ApiKey{} = key <-
           Enum.find(Lei.ApiKeys.list_keys(org), &(to_string(&1.id) == key_id)),
         {:ok, _} <- Lei.ApiKeys.revoke_key(key.id) do
      json_resp(conn, 200, %{status: "revoked"})
    else
      {:error, status, body} when is_integer(status) -> json_resp(conn, status, body)
      _ -> json_resp(conn, 404, %{error: "key not found"})
    end
  end

  # An operator (a JWT signed with the deployment's secret) may manage any org.
  # Otherwise the caller must hold an "admin" key belonging to this org.
  defp authorize_org(conn, slug) do
    not_found = {:error, 404, %{error: "org not found"}}

    case {conn.assigns[:auth_method], conn.assigns[:current_api_key],
          Lei.ApiKeys.get_org_by_slug(slug)} do
      {_, _, nil} ->
        not_found

      {:jwt, _, org} ->
        {:ok, org}

      {_, %Lei.ApiKey{org_id: org_id, scopes: scopes}, %Lei.Org{id: org_id} = org} ->
        if "admin" in scopes, do: {:ok, org}, else: not_found

      _ ->
        not_found
    end
  end

  # Scopes an org admin may grant. "cache" reaches every customer's reports and
  # is an operator's to hand out; "admin" here means admin of the same org.
  @self_service_scopes ["admin", "analyze"]

  defp authorize_scopes(conn, scopes) when is_list(scopes) do
    cond do
      conn.assigns[:auth_method] == :jwt -> :ok
      Enum.all?(scopes, &(&1 in @self_service_scopes)) -> :ok
      true -> {:error, 403, %{error: "scope not grantable", grantable: @self_service_scopes}}
    end
  end

  defp authorize_scopes(_conn, _scopes), do: {:error, 422, %{error: "scopes must be a list"}}

  # Unauthenticated health/metrics endpoints (outside /v1 prefix)

  get "/healthz" do
    data = Lei.Health.liveness()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Poison.encode!(data))
  end

  get "/readyz" do
    # The mode is derived from the key, so this is what is actually serving,
    # not what someone intended. The canary asserts it.
    data =
      Lei.Health.readiness()
      |> Map.put(:stripe_mode, Lei.Stripe.Mode.current())

    # "degraded" still serves traffic -- only a required dependency failing
    # ("error") should pull this instance out of rotation.
    status = if data.status == "error", do: 503, else: 200

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Poison.encode!(data))
  end

  get "/metrics" do
    metrics = Lei.Metrics.collect()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Poison.encode!(%{error: "not found"}))
  end

  # --- Private helpers ---

  defp signup_free(conn, name) do
    case Lei.ApiKeys.create_org(name, tier: "free", status: "active") do
      {:error, :name_taken} ->
        render_page(conn, "signup.html.eex",
          flash_error: "That organization name is already taken. Please choose another."
        )

      {:ok, org} ->
        case Lei.ApiKeys.create_api_key(org, "admin", ["admin", "analyze"]) do
          {:ok, raw_key, _api_key} ->
            {:ok, recovery_code} = Lei.ApiKeys.generate_recovery_code(org)

            render_page(conn, "signup_success.html.eex",
              org_name: org.name,
              raw_key: raw_key,
              recovery_code: recovery_code
            )

          {:error, _changeset} ->
            render_page(conn, "signup.html.eex",
              flash_error: "Failed to create API key. Please try again."
            )
        end

      {:error, _changeset} ->
        render_page(conn, "signup.html.eex",
          flash_error: "Failed to create organization. Please try again."
        )
    end
  end

  defp signup_pro(conn, name) do
    case Lei.ApiKeys.create_org(name, tier: "pro", status: "pending") do
      {:error, :name_taken} ->
        render_page(conn, "signup.html.eex",
          flash_error: "That organization name is already taken. Please choose another."
        )

      {:ok, org} ->
        base_url = Application.get_env(:lowendinsight, :lei_base_url, "http://localhost:4000")
        price_id = Application.get_env(:lowendinsight, :stripe_pro_price_id)
        metered_price_id = Application.get_env(:lowendinsight, :stripe_metered_price_id)
        stripe = Lei.Stripe.impl()

        case stripe.create_checkout_session(%{
               price_id: price_id,
               metered_price_id: metered_price_id,
               success_url: "#{base_url}/signup/success?session_id={CHECKOUT_SESSION_ID}",
               cancel_url: "#{base_url}/signup",
               org_id: org.id
             }) do
          {:ok, %{"url" => checkout_url}} ->
            conn
            |> fetch_session()
            |> put_session("pending_org_id", org.id)
            |> put_resp_header("location", checkout_url)
            |> send_resp(302, "")

          {:error, _reason} ->
            render_page(conn, "signup.html.eex",
              flash_error: "Failed to create payment session. Please try again."
            )
        end

      {:error, _changeset} ->
        render_page(conn, "signup.html.eex",
          flash_error: "Failed to create organization. Please try again."
        )
    end
  end

  defp put_secret_key_base(conn, _opts) do
    secret = Application.get_env(:lowendinsight, :session_secret_key_base)
    Map.put(conn, :secret_key_base, secret)
  end

  defp render_page(conn, template, assigns \\ []) do
    tpl_dir = Path.join(:code.priv_dir(@otp_app) |> to_string(), "templates")
    assigns = Keyword.put(assigns, :conn, conn)
    inner = EEx.eval_file(Path.join(tpl_dir, template), assigns: Enum.into(assigns, %{}))
    layout_assigns = Keyword.put(assigns, :inner_content, inner)

    body =
      EEx.eval_file(Path.join(tpl_dir, "layout.html.eex"),
        assigns: Enum.into(layout_assigns, %{})
      )

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, body)
  end

  defp validate_batch_request(params) do
    dependencies = params["dependencies"]

    cond do
      is_nil(dependencies) ->
        {:error, "missing required field: dependencies"}

      not is_list(dependencies) ->
        {:error, "dependencies must be an array"}

      Enum.empty?(dependencies) ->
        {:error, "dependencies must not be empty"}

      not Enum.all?(dependencies, &valid_dependency?/1) ->
        {:error, "each dependency must have ecosystem, package, and version fields"}

      true ->
        opts = [
          cache_mode: params["cache_mode"] || "stale",
          include_transitive: params["include_transitive"] || false
        ]

        {:ok, dependencies, opts}
    end
  end

  defp valid_dependency?(dep) when is_map(dep) do
    is_binary(dep["ecosystem"]) and is_binary(dep["package"]) and is_binary(dep["version"])
  end

  defp valid_dependency?(_), do: false

  defp json_resp(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Poison.encode!(data))
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
