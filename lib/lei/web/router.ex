defmodule Lei.Web.Router do
  use Plug.Router

  plug Plug.Logger
  plug :match
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  plug :dispatch

  post "/v1/analyze/batch" do
    case conn.body_params do
      %{"dependencies" => deps} when is_list(deps) and length(deps) > 0 ->
        result = Lei.BatchAnalyzer.analyze(deps)
        send_json(conn, 200, result)

      %{"dependencies" => []} ->
        send_json(conn, 400, %{"error" => "dependencies list cannot be empty"})

      _ ->
        send_json(conn, 400, %{"error" => "request must include a 'dependencies' array"})
    end
  end

  get "/v1/health" do
    send_json(conn, 200, %{"status" => "ok"})
  end

  match _ do
    send_json(conn, 404, %{"error" => "not found"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
