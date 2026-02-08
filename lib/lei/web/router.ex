# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Web.Router do
  @moduledoc """
  HTTP router for the LEI batch analysis API.

  Provides:
  - `POST /v1/analyze/batch` - Analyze an entire SBOM in a single request
  - `GET /v1/jobs/:id` - Check status of a pending analysis job
  - `GET /health` - Health check endpoint
  """

  use Plug.Router

  plug Plug.Logger
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Poison
  plug :dispatch

  post "/v1/analyze/batch" do
    case validate_batch_request(conn.body_params) do
      {:ok, deps, opts} ->
        result = Lei.BatchAnalyzer.analyze(deps, opts)
        send_json(conn, 200, result)

      {:error, message} ->
        send_json(conn, 400, %{"error" => message})
    end
  end

  get "/v1/jobs/:id" do
    case Lei.Registry.get_job(id) do
      {:ok, job} ->
        send_json(conn, 200, %{
          "job_id" => id,
          "status" => to_string(job.status),
          "created_at" => job.created_at,
          "result" => job.result
        })

      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "Job not found"})
    end
  end

  get "/health" do
    send_json(conn, 200, %{"status" => "ok"})
  end

  match _ do
    send_json(conn, 404, %{"error" => "Not found"})
  end

  defp validate_batch_request(%{"dependencies" => deps}) when is_list(deps) do
    case validate_dependencies(deps) do
      :ok ->
        opts = []
        {:ok, deps, opts}

      {:error, _} = err ->
        err
    end
  end

  defp validate_batch_request(_) do
    {:error, "Request body must include a 'dependencies' array"}
  end

  defp validate_dependencies([]), do: {:error, "Dependencies list cannot be empty"}

  defp validate_dependencies(deps) when length(deps) > 500 do
    {:error, "Maximum 500 dependencies per request"}
  end

  defp validate_dependencies(deps) do
    invalid =
      Enum.find(deps, fn dep ->
        not (is_map(dep) and is_binary(dep["ecosystem"]) and is_binary(dep["package"]) and
               is_binary(dep["version"]))
      end)

    if invalid do
      {:error, "Each dependency must have 'ecosystem', 'package', and 'version' string fields"}
    else
      :ok
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Poison.encode!(body))
  end
end
