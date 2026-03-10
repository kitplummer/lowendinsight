defmodule Lei.Web.Router do
  @moduledoc """
  HTTP router for LEI batch analysis API and web UI.

  Provides the POST /v1/analyze/batch endpoint for analyzing
  lists of dependencies with parallel cache lookups, plus
  HTML signup/login/dashboard routes.
  """
  use Plug.Router

  @otp_app :lowendinsight

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
    _session_id = conn.params["session_id"]
    org_id = get_session(conn, "pending_org_id")

    cond do
      is_nil(org_id) ->
        render_page(conn, "signup.html.eex",
          flash_error: "No pending signup found. Please try again."
        )

      true ->
        case Lei.Repo.get(Lei.Org, org_id) do
          nil ->
            render_page(conn, "signup.html.eex", flash_error: "Organization not found.")

          %Lei.Org{status: "active"} = org ->
            # Already activated by webhook, show credentials
            show_signup_success(conn, org)

          %Lei.Org{} = org ->
            # Webhook hasn't fired yet — activate now (Stripe success URL is reliable)
            {:ok, org} = Lei.ApiKeys.activate_org(org)
            show_signup_success(conn, org)
        end
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

    case stripe.construct_webhook_event(raw_body, signature, webhook_secret) do
      {:ok, event} ->
        Lei.StripeWebhookHandler.handle_event(event)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Poison.encode!(%{status: "ok"}))

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Poison.encode!(%{error: "invalid webhook signature"}))
    end
  end

  # --- JSON API routes ---

  post "/v1/analyze/batch" do
    case validate_batch_request(conn.body_params) do
      {:ok, dependencies, opts} ->
        case maybe_check_quota(conn) do
          {:ok, _} ->
            result = Lei.BatchAnalyzer.analyze(dependencies, opts)
            cached = result.summary.cached
            pending = result.summary.pending

            # Record usage async if API key auth
            {org_id, api_key_id, tier} = extract_billing_context(conn)

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

          {:error, :quota_exceeded, info} ->
            json_resp(conn, 402, %{
              error: "free_tier_quota_exceeded",
              used: info.used,
              limit: info.limit,
              upgrade_url: "https://lowendinsight.fly.dev/signup?tier=pro"
            })
        end

      {:error, message} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Poison.encode!(%{error: message}))
    end
  end

  get "/v1/usage" do
    case extract_billing_context(conn) do
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
    stats = Lei.BatchCache.stats()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Poison.encode!(%{status: "ok", cache: stats}))
  end

  # --- Self-registration endpoints ---

  post "/v1/orgs" do
    case conn.body_params do
      %{"name" => name} when is_binary(name) and name != "" ->
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

  post "/v1/orgs/:slug/keys" do
    case Lei.ApiKeys.get_org_by_slug(slug) do
      nil ->
        json_resp(conn, 404, %{error: "org not found"})

      org ->
        name = get_in(conn.body_params, ["name"]) || "default"
        scopes = get_in(conn.body_params, ["scopes"]) || []

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
    end
  end

  get "/v1/orgs/:slug/keys" do
    case Lei.ApiKeys.get_org_by_slug(slug) do
      nil ->
        json_resp(conn, 404, %{error: "org not found"})

      org ->
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
    end
  end

  delete "/v1/orgs/:slug/keys/:key_id" do
    case Lei.ApiKeys.get_org_by_slug(slug) do
      nil ->
        json_resp(conn, 404, %{error: "org not found"})

      _org ->
        case Lei.ApiKeys.revoke_key(key_id) do
          {:ok, _} -> json_resp(conn, 200, %{status: "revoked"})
          {:error, :not_found} -> json_resp(conn, 404, %{error: "key not found"})
        end
    end
  end

  # Unauthenticated health/metrics endpoints (outside /v1 prefix)

  get "/healthz" do
    data = Lei.Health.liveness()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Poison.encode!(data))
  end

  get "/readyz" do
    data = Lei.Health.readiness()
    status = if data.status == "ok", do: 200, else: 503

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
    case Lei.ApiKeys.find_or_create_org(name, tier: "free", status: "active") do
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
    case Lei.ApiKeys.find_or_create_org(name, tier: "pro", status: "pending") do
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

  defp show_signup_success(conn, org) do
    case Lei.ApiKeys.create_api_key(org, "admin", ["admin", "analyze"]) do
      {:ok, raw_key, _api_key} ->
        {:ok, recovery_code} = Lei.ApiKeys.generate_recovery_code(org)

        conn
        |> fetch_session()
        |> delete_session("pending_org_id")
        |> render_page("signup_success.html.eex",
          org_name: org.name,
          raw_key: raw_key,
          recovery_code: recovery_code
        )

      {:error, _} ->
        render_page(conn, "signup.html.eex",
          flash_error: "Failed to create API key. Please try again."
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

  defp extract_billing_context(conn) do
    case conn.assigns[:current_api_key] do
      nil ->
        {nil, nil, nil}

      api_key ->
        {api_key.org.id, api_key.id, api_key.org.tier}
    end
  end

  defp maybe_check_quota(conn) do
    case extract_billing_context(conn) do
      {nil, _, _} ->
        {:ok, :no_billing}

      {_org_id, _, "pro"} ->
        {:ok, :pro}

      {org_id, _, _tier} when not is_nil(org_id) ->
        case Lei.UsageTracker.check_free_tier_quota(org_id) do
          {:ok, _remaining} -> {:ok, :within_quota}
          {:error, :quota_exceeded, info} -> {:error, :quota_exceeded, info}
          {:error, _} -> {:ok, :unknown}
        end
    end
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
