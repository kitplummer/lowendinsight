defmodule Lei.Web.Router do
  @moduledoc """
  HTTP router for LEI batch analysis API.

  Provides the POST /v1/analyze/batch endpoint for analyzing
  lists of dependencies with parallel cache lookups.
  """
  use Plug.Router

  plug Plug.Logger
  plug Plug.Parsers, parsers: [:json], json_decoder: Poison
  plug Lei.Auth
  plug :match
  plug :dispatch

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

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Poison.encode!(%{error: "not found"}))
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
