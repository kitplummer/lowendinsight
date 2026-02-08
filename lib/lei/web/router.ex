defmodule Lei.Web.Router do
  @moduledoc """
  HTTP router for LEI batch analysis API.

  Provides the POST /v1/analyze/batch endpoint for analyzing
  lists of dependencies with parallel cache lookups.
  """
  use Plug.Router

  plug Plug.Logger
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Poison
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
end
