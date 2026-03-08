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

  plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Poison)
  plug(Lei.Auth)
  plug(:match)
  plug(:dispatch)

  # --- HTML UI routes ---

  get "/signup" do
    render_page(conn, "signup.html.eex")
  end

  post "/signup" do
    name = conn.body_params["name"]

    if is_nil(name) or name == "" do
      render_page(conn, "signup.html.eex", flash_error: "Organization name is required.")
    else
      case Lei.ApiKeys.find_or_create_org(name) do
        {:ok, org} ->
          case Lei.ApiKeys.create_api_key(org, "admin", ["admin", "analyze"]) do
            {:ok, raw_key, _api_key} ->
              render_page(conn, "signup_success.html.eex", org_name: org.name, raw_key: raw_key)

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

  get "/logout" do
    conn
    |> fetch_session()
    |> clear_session()
    |> put_resp_header("location", "/login")
    |> send_resp(302, "")
  end

  # --- JSON API routes ---

  post "/v1/analyze/batch" do
    case validate_batch_request(conn.body_params) do
      {:ok, dependencies, opts} ->
        result = Lei.BatchAnalyzer.analyze(dependencies, opts)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Poison.encode!(result))

      {:error, message} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Poison.encode!(%{error: message}))
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
