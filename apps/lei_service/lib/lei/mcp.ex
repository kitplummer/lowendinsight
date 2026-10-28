defmodule Lei.Mcp do
  @moduledoc """
  `/mcp`: the analysis as a remote MCP server.

  Streamable HTTP, stateless, answering every request with JSON rather than an
  event stream. A tool that looks something up is a request and a response;
  there is nothing to push, so there is no session, no `Mcp-Session-Id` and no
  stream to open (`GET` and `DELETE` are 405). JSON-RPC batches were removed
  from the protocol in 2025-06-18 and are refused.

  ## Who may call it

  A `lei_` API key with the `analyze` scope (or `admin`), or an operator token
  -- the same credentials as the API, checked here because `/mcp` is not under
  `/v1`, where the API's auth plugs run. Anything else is a 401 with a
  `WWW-Authenticate` challenge. A payment credential is not accepted: there are
  no payment challenges on `/mcp`, because an MCP client is not an HTTP client
  at the tool level and has nowhere to handle a 402. An org that cannot pay is
  told so in a tool result.

  Every request counts against the key's one allowance, the `api:` bucket the
  API's routes share. A browser page on another origin is refused, which is
  what the protocol asks of a server against DNS rebinding.

  ## Billing

  `check_packages` is `POST /v1/analyze/batch`: `Lei.Batch` validates, prices
  and runs it, and `Lei.Payments.Gate.decide/2` admits and charges it. Only
  the answer differs.

  `analyze_repositories` is `POST /v1/analyze` the same way, through
  `Lei.Analyze`. Work that does not finish within the call is charged at
  admission and collected with `get_analysis`, which is
  `GET /v1/analyze/{uuid}` and bills nothing -- so an agent is told to collect
  rather than ask again, which would be charged again.
  """

  @behaviour Plug

  import Plug.Conn

  alias Lei.Payments.Gate

  # Newest first: an initialize asking for a version not listed is answered
  # with the first.
  @protocol_versions ["2025-06-18", "2025-03-26"]

  @check_packages %{
    name: "check_packages",
    title: "Check packages",
    # Written for the agent choosing a tool, trigger first (see the reasoning
    # in clients/mcp/lei_mcp.py): an agent does not know its knowledge of a
    # package is dated, so the description has to say so.
    description:
      "Call this before you recommend, add, or vouch for a dependency, and " <>
        "whenever you are about to say whether a package is maintained. Your " <>
        "training data has a cutoff: a package that looked healthy in it may have " <>
        "lost its maintainer or gone quiet since, and nothing in you will flag " <>
        "that. Pass every package you are weighing in one call -- a shortlist, a " <>
        "manifest, a lockfile. A package already analysed comes back with its " <>
        "risk now. One that is not is queued and comes back \"pending\": call " <>
        "again with the same packages in a minute or two. Asking about a pending " <>
        "package again is not charged.",
    inputSchema: %{
      type: "object",
      properties: %{
        dependencies: %{
          type: "array",
          minItems: 1,
          items: %{
            type: "object",
            properties: %{
              ecosystem: %{
                type: "string",
                enum: ["npm", "pypi", "hex", "cargo", "gem", "composer", "go"]
              },
              package: %{type: "string"},
              version: %{type: "string"}
            },
            required: ["ecosystem", "package", "version"]
          }
        }
      },
      required: ["dependencies"]
    },
    annotations: %{readOnlyHint: true, openWorldHint: true}
  }

  @analyze_repositories %{
    name: "analyze_repositories",
    title: "Analyze repositories",
    description:
      "Call this when you have a project's git repository URL rather than a " <>
        "package name -- a fork, a vendored library, a project with no " <>
        "registry release -- and you are about to depend on it or say whether " <>
        "it is maintained. Your training data has a cutoff, and a repository " <>
        "that looked active in it may have gone quiet since. Pass every " <>
        "repository you are weighing in one call. One already analysed comes " <>
        "back with its risk now. One that is not is analysed, which takes up " <>
        "to a few minutes: if it is not done within the call, the result is " <>
        "\"incomplete\" with a uuid -- call get_analysis with that uuid to " <>
        "collect it, which is not charged. Calling this tool again instead " <>
        "is charged again.",
    inputSchema: %{
      type: "object",
      properties: %{
        urls: %{
          type: "array",
          minItems: 1,
          items: %{
            type: "string",
            description: "A git repository URL, e.g. https://github.com/owner/repo"
          }
        }
      },
      required: ["urls"]
    },
    annotations: %{readOnlyHint: true, openWorldHint: true}
  }

  @get_analysis %{
    name: "get_analysis",
    title: "Get analysis",
    description:
      "Collect the result of an analyze_repositories call that came back " <>
        "\"incomplete\", by its uuid. Not charged: the analysis was paid for " <>
        "when it was requested. If it is still incomplete, wait a minute and " <>
        "call this again.",
    inputSchema: %{
      type: "object",
      properties: %{uuid: %{type: "string"}},
      required: ["uuid"]
    },
    annotations: %{readOnlyHint: true, openWorldHint: false}
  }

  @tools [@check_packages, @analyze_repositories, @get_analysis]

  @doc "The protocol versions served, newest first."
  def protocol_versions, do: @protocol_versions

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with :ok <- check_origin(conn),
         :ok <- check_method(conn),
         :ok <- check_protocol_version(conn),
         {:ok, conn} <- authenticate(conn),
         {:ok, conn} <- check_rate_limit(conn) do
      handle(conn, conn.body_params)
    else
      {:halt, conn} -> conn
    end
  end

  # --- transport ---

  # Absent for a client that is not a browser, which is every remote MCP
  # client calling from a server. Present, it must be this service's own.
  defp check_origin(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin] ->
        if origin in allowed_origins(),
          do: :ok,
          else: {:halt, http_error(conn, 403, "origin not allowed")}

      _ ->
        {:halt, http_error(conn, 403, "origin not allowed")}
    end
  end

  defp allowed_origins do
    Application.get_env(:lei_service, :mcp_allowed_origins) ||
      [Application.get_env(:lei_service, :lei_base_url, "http://localhost:4000")]
  end

  defp check_method(%Plug.Conn{method: "POST"}), do: :ok

  defp check_method(conn) do
    {:halt,
     conn
     |> put_resp_header("allow", "POST")
     |> http_error(405, "POST only: this server does not open event streams")}
  end

  # Sent by a client on every request after initialize. Absent, the protocol
  # says to assume 2025-03-26, which is served.
  defp check_protocol_version(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        :ok

      [version] when version in @protocol_versions ->
        :ok

      _ ->
        {:halt, http_error(conn, 400, "unsupported MCP-Protocol-Version")}
    end
  end

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer lei_" <> _ = header] -> authenticate_key(conn, header)
      ["Bearer " <> jwt] when jwt != "" -> authenticate_operator(conn, jwt)
      _ -> {:halt, unauthorized(conn, nil)}
    end
  end

  defp authenticate_key(conn, "Bearer " <> raw_key) do
    case Lei.ApiKeys.authenticate_key(raw_key) do
      {:ok, api_key} ->
        if "analyze" in api_key.scopes or "admin" in api_key.scopes do
          Lei.ApiKeys.touch_last_used(api_key)

          {:ok, conn |> assign(:current_api_key, api_key) |> assign(:auth_method, :api_key)}
        else
          {:halt, http_error(conn, 403, "insufficient scope", %{required: "analyze"})}
        end

      {:error, {:org_not_active, status}} ->
        {:halt, http_error(conn, 403, "organization not active", %{status: status})}

      {:error, _} ->
        {:halt, unauthorized(conn, "invalid_token")}
    end
  end

  defp authenticate_operator(conn, jwt) do
    case Lei.OperatorToken.verify(jwt) do
      {:ok, _} -> {:ok, assign(conn, :auth_method, :jwt)}
      {:error, _} -> {:halt, unauthorized(conn, "invalid_token")}
    end
  end

  defp unauthorized(conn, error) do
    challenge =
      case error do
        nil -> ~s(Bearer realm="lowendinsight")
        error -> ~s(Bearer realm="lowendinsight", error="#{error}")
      end

    conn
    |> put_resp_header("www-authenticate", challenge)
    |> http_error(401, "a lei_ API key is required: #{signup_url()}")
  end

  # The key's one allowance (#335). An operator token is not limited, as on
  # the API.
  defp check_rate_limit(%Plug.Conn{assigns: %{auth_method: :api_key}} = conn) do
    api_key = conn.assigns.current_api_key

    case Lei.RateLimiter.check("api:#{api_key.key_prefix}", api_key.org.tier) do
      {:ok, remaining} ->
        {:ok, put_resp_header(conn, "x-ratelimit-remaining", to_string(remaining))}

      {:error, :rate_limited, retry_after} ->
        retry_secs = Lei.RateLimiter.retry_after_seconds(retry_after)

        {:halt,
         conn
         |> put_resp_header("retry-after", to_string(retry_secs))
         |> http_error(429, "rate limit exceeded", %{retry_after: retry_secs})}
    end
  end

  defp check_rate_limit(conn), do: {:ok, conn}

  # --- JSON-RPC ---

  # Plug.Parsers puts a JSON body that is not an object under "_json".
  defp handle(conn, %{"_json" => list}) when is_list(list),
    do: rpc_error(conn, 400, nil, -32600, "JSON-RPC batches are not supported")

  defp handle(conn, %{"jsonrpc" => "2.0", "method" => method, "id" => id} = message) do
    case request(conn, method, object(message["params"])) do
      {:result, result} -> send_json(conn, 200, %{jsonrpc: "2.0", id: id, result: result})
      {:error, code, text} -> rpc_error(conn, 200, id, code, text)
    end
  end

  # A notification, or a response to a request this server never sends.
  defp handle(conn, %{"jsonrpc" => "2.0"} = message)
       when not is_map_key(message, "id") or not is_map_key(message, "method") do
    send_resp(conn, 202, "")
  end

  defp handle(conn, _body),
    do: rpc_error(conn, 400, nil, -32600, "not a JSON-RPC 2.0 message")

  # Params and arguments are objects in the protocol. Anything else is read as
  # none, rather than indexed into and raised on.
  defp object(%{} = map), do: map
  defp object(_), do: %{}

  defp request(_conn, "initialize", params) do
    requested = params["protocolVersion"]
    version = if requested in @protocol_versions, do: requested, else: hd(@protocol_versions)

    {:result,
     %{
       protocolVersion: version,
       capabilities: %{tools: %{listChanged: false}},
       serverInfo: %{
         name: "lowendinsight",
         title: "LowEndInsight",
         version: to_string(Application.spec(:lei_service, :vsn))
       },
       instructions:
         "Dependency risk as it stands today: maintenance, contributors, and " <>
           "recency of real work, from each package's repository."
     }}
  end

  defp request(_conn, "ping", _params), do: {:result, %{}}

  defp request(_conn, "tools/list", _params), do: {:result, %{tools: @tools}}

  defp request(conn, "tools/call", %{"name" => "check_packages"} = params) do
    Lei.Adoption.record_bucket("mcp-remote")
    {:result, check_packages(conn, object(params["arguments"]))}
  end

  defp request(conn, "tools/call", %{"name" => "analyze_repositories"} = params) do
    Lei.Adoption.record_bucket("mcp-remote")
    {:result, analyze_repositories(conn, object(params["arguments"]))}
  end

  # Collecting is not adoption: the call that started the work was counted.
  defp request(_conn, "tools/call", %{"name" => "get_analysis"} = params) do
    {:result, get_analysis(object(params["arguments"]))}
  end

  defp request(_conn, "tools/call", %{"name" => name}),
    do: {:error, -32602, "unknown tool: #{inspect(name)}"}

  defp request(_conn, method, _params), do: {:error, -32601, "method not found: #{method}"}

  # --- tools ---

  defp check_packages(conn, arguments) do
    case Lei.Batch.validate(%{"dependencies" => arguments["dependencies"]}) do
      {:ok, dependencies, opts} ->
        {split, admission} = Lei.Batch.price(dependencies, opts)

        case Gate.decide(conn, admission) do
          {:ok, {org_id, _api_key_id, tier}} ->
            tool_result(Lei.Batch.run(dependencies, opts, {org_id, tier}, split))

          refusal ->
            refused(refusal)
        end

      {:too_many, body} ->
        tool_error("Too many packages in one call.", body)

      {:error, message} ->
        tool_error(message, %{error: message})
    end
  end

  # POST /v1/analyze, through the same Lei.Analyze path, with the route's
  # defaults: blocking, up to the default timeout.
  defp analyze_repositories(conn, arguments) do
    case Lei.Analyze.validate(%{"urls" => arguments["urls"]}) do
      {:ok, request} ->
        {split, admission} = Lei.Analyze.price(request.urls)

        case Gate.decide(conn, admission) do
          {:ok, billing} ->
            context = %{
              uuid: UUID.uuid4(),
              start_time: DateTime.utc_now(),
              route: "/mcp",
              api_key: conn.assigns[:current_api_key]
            }

            analyzed(Lei.Analyze.run(request, billing, split, context))

          refusal ->
            refused(refusal)
        end

      {:invalid, body} ->
        tool_error(body[:message] || body[:error], body)
    end
  end

  defp analyzed({:ok, body}), do: job_result(Poison.decode!(body))
  defp analyzed({:incomplete, body}), do: job_result(stringify(body))
  defp analyzed({:error, error}), do: tool_error(to_string(error), %{error: error})
  defp analyzed({:not_queued, body}), do: tool_error(body.message, body)

  defp get_analysis(arguments) do
    case Lei.Analyze.job(arguments["uuid"]) do
      {:ok, job} -> job_result(Poison.decode!(job))
      {_refused, message} -> tool_error(message, %{error: message})
    end
  end

  # An incomplete job says how to collect it, so the model is not left to
  # guess -- and does not guess "call analyze_repositories again", which is
  # charged again.
  defp job_result(%{"state" => "complete"} = job), do: tool_result(job)

  defp job_result(%{"uuid" => uuid} = job) do
    tool_result(
      Map.put(
        job,
        "next",
        "Still running. Call get_analysis with uuid #{uuid} in a minute to " <>
          "collect it; that is not charged."
      )
    )
  end

  defp job_result(job), do: tool_result(job)

  defp stringify(map), do: map |> Poison.encode!() |> Poison.decode!()

  # Said in terms of what to do next, for a model reading it.
  defp refused({:quota_exceeded, detail}) do
    url = Gate.upgrade_url()

    tool_error(
      "This account's free monthly allowance is spent, so nothing was analysed " <>
        "or charged. A Pro plan raises it: #{url}",
      Map.merge(%{error: "free_tier_quota_exceeded", upgrade_url: url}, detail)
    )
  end

  defp refused({:payment_required, _org_id, credits}) do
    tool_error(
      "This account's credits do not cover this call, so nothing was analysed " <>
        "or charged. Top up at least #{credits} credits at #{dashboard_url()}",
      %{error: "insufficient_credits", top_up_credits: credits}
    )
  end

  defp refused(:billing_unavailable) do
    tool_error(
      "Billing is unavailable right now, so nothing was analysed or charged. Try again shortly.",
      %{error: "billing_unavailable"}
    )
  end

  defp tool_result(result) do
    %{content: [%{type: "text", text: Poison.encode!(result)}], structuredContent: result}
  end

  defp tool_error(text, structured) do
    %{content: [%{type: "text", text: text}], structuredContent: structured, isError: true}
  end

  # --- responses ---

  defp rpc_error(conn, status, id, code, message) do
    send_json(conn, status, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
  end

  defp http_error(conn, status, message, extra \\ %{}) do
    send_json(conn, status, Map.put(extra, :error, message))
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Poison.encode!(body))
    |> halt()
  end

  defp base_url, do: Application.get_env(:lei_service, :lei_base_url, "http://localhost:4000")
  defp signup_url, do: base_url() <> "/signup"
  defp dashboard_url, do: base_url() <> "/dashboard"
end
