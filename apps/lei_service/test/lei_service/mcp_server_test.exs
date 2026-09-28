defmodule LeiService.McpServerTest do
  @moduledoc """
  The MCP server, spoken to rather than read.

  `/llms.txt` is the landing and not the road: an agent does not browse, it uses
  what is in its tool list. This puts the analysis in that list, which is the
  only mechanism by which an agent comes to use the service while deciding what
  to depend on.

  Every assertion here drives the real process over stdio, because the thing
  being tested is a protocol conversation. A test that grepped the file for tool
  names would pass for a server that never answers `initialize`.

  Dependency-free on purpose. A tool whose subject is dependency risk should not
  ask anyone to install a tree of packages to run it, and one file with no
  imports beyond the standard library is auditable in a sitting.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @server "clients/mcp/lei_mcp.py"

  # Newline-delimited JSON-RPC, which is what MCP's stdio transport uses.
  defp talk(requests, env \\ []) do
    input = Enum.map_join(requests, "", &(Jason.encode!(&1) <> "\n"))

    {out, status} =
      System.cmd("python3", [@server],
        cd: @root,
        stderr_to_stdout: false,
        env: [{"LEI_API_KEY", ""}, {"LEI_BASE_URL", "http://127.0.0.1:9"}] ++ env,
        into: "",
        # stdin is not settable via System.cmd, so the script is fed by a shell.
        arg0: "python3"
      )

    {out, status}
  rescue
    _ -> {:unsupported, 0}
  end

  defp rpc(requests, env \\ []) do
    input = Enum.map_join(requests, "", &(Jason.encode!(&1) <> "\n"))
    script = "printf '%s' " <> inline_quote(input) <> " | python3 " <> @server

    {out, _status} =
      System.cmd("bash", ["-c", script],
        cd: @root,
        stderr_to_stdout: false,
        env: [{"LEI_API_KEY", ""}, {"LEI_BASE_URL", "http://127.0.0.1:9"}] ++ env
      )

    out
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp inline_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp initialize do
    %{
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: %{
        protocolVersion: "2024-11-05",
        capabilities: %{},
        clientInfo: %{name: "t", version: "1"}
      }
    }
  end

  describe "it speaks MCP" do
    test "initialize is answered with a protocol version and a server name" do
      [reply] = rpc([initialize()])

      assert reply["id"] == 1
      assert reply["result"]["protocolVersion"] =~ ~r/^\d{4}-\d{2}-\d{2}$/
      assert reply["result"]["serverInfo"]["name"] =~ "lowendinsight"
      assert reply["result"]["capabilities"]["tools"]
    end

    test "an unknown method is an error, not silence" do
      # A server that ignores what it does not understand leaves the client
      # waiting, which presents as a hung agent rather than a failure.
      [_init, reply] =
        rpc([initialize(), %{jsonrpc: "2.0", id: 2, method: "no/such/method", params: %{}}])

      assert reply["id"] == 2
      assert reply["error"]["code"] == -32601
    end

    test "a notification gets no reply, as the protocol requires" do
      # notifications/initialized has no id; answering it corrupts the stream.
      replies = rpc([initialize(), %{jsonrpc: "2.0", method: "notifications/initialized"}])

      assert length(replies) == 1, "the server replied to a notification"
    end
  end

  describe "the tools it offers" do
    test "both analysis tools are listed, with schemas" do
      [_init, reply] =
        rpc([initialize(), %{jsonrpc: "2.0", id: 2, method: "tools/list", params: %{}}])

      names = Enum.map(reply["result"]["tools"], & &1["name"]) |> Enum.sort()
      assert "analyze_repository" in names
      assert "analyze_dependencies" in names

      one = Enum.find(reply["result"]["tools"], &(&1["name"] == "analyze_repository"))
      assert one["inputSchema"]["required"] == ["url"]
      assert one["inputSchema"]["properties"]["url"]
    end

    test "the descriptions say when to reach for it, not what it computes" do
      # An agent picks a tool from its description. "Analyses a repository" wins
      # nothing; the reason to call it is that a model cannot know whether a
      # package is maintained *now*.
      [_init, reply] =
        rpc([initialize(), %{jsonrpc: "2.0", id: 2, method: "tools/list", params: %{}}])

      text =
        reply["result"]["tools"] |> Enum.map_join(" ", & &1["description"]) |> String.downcase()

      assert text =~ "training",
             "nothing tells the agent this covers what its training data cannot"

      assert text =~ "dependency" or text =~ "depend"
    end
  end

  describe "it fails in ways an agent can act on" do
    test "a missing API key says so, and says it is free during beta" do
      [_init, reply] =
        rpc([
          initialize(),
          %{
            jsonrpc: "2.0",
            id: 2,
            method: "tools/call",
            params: %{name: "analyze_repository", arguments: %{url: "https://github.com/o/r"}}
          }
        ])

      assert reply["result"]["isError"] == true
      text = reply["result"]["content"] |> Enum.map_join(" ", & &1["text"])

      assert text =~ "LEI_API_KEY",
             "the agent is not told which credential is missing:\n#{text}"

      assert text =~ "beta" or text =~ "free",
             "the agent is not told an account costs nothing right now"
    end

    test "an unreachable service reports that, rather than an empty result" do
      [_init, reply] =
        rpc(
          [
            initialize(),
            %{
              jsonrpc: "2.0",
              id: 2,
              method: "tools/call",
              params: %{name: "analyze_repository", arguments: %{url: "https://github.com/o/r"}}
            }
          ],
          [{"LEI_API_KEY", "lei_fake"}]
        )

      assert reply["result"]["isError"] == true
      text = reply["result"]["content"] |> Enum.map_join(" ", & &1["text"])

      refute text == "", "an unreachable service produced an empty answer"

      assert text =~ "127.0.0.1:9" or text =~ "could not reach" or text =~ "Connection",
             "the failure does not say what it could not reach:\n#{text}"
    end

    test "an unknown tool name is refused" do
      [_init, reply] =
        rpc([
          initialize(),
          %{jsonrpc: "2.0", id: 2, method: "tools/call", params: %{name: "rm_rf", arguments: %{}}}
        ])

      assert reply["result"]["isError"] == true or reply["error"]
    end
  end

  describe "a report that determined nothing says so" do
    # Found by running it. A repository the service could not analyse comes back
    # with data.error set and everything else undetermined; the first renderer
    # ignored the error and printed "overall risk rating: undetermined" and
    # nothing else. The agent gets a near-empty answer with no reason, which is
    # this codebase's recurring shape -- reporting success while broken.
    # Answered by a stub service, not by grepping the renderer. The first
    # version asserted that `get("error")` appeared in the file -- which it
    # still does, in a second place, so the mutation that stops the renderer
    # reading it passed the guard. Sixth time in this session that asserting
    # text exists rather than that behaviour happens produced a guard measuring
    # nothing.
    defp against_stub(body) do
      port = 40_000 + :erlang.phash2(body, 10_000)

      script = """
      python3 - <<'STUB' &
      import http.server, json
      BODY = #{inspect(body)}
      class H(http.server.BaseHTTPRequestHandler):
          def do_POST(s):
              s.send_response(200); s.send_header('Content-Type','application/json'); s.end_headers()
              s.wfile.write(BODY.encode())
          def log_message(*a): pass
      http.server.HTTPServer(('127.0.0.1', #{port}), H).serve_forever()
      STUB
      STUB_PID=$!
      for _ in $(seq 1 40); do
        (exec 3<>/dev/tcp/127.0.0.1/#{port}) 2>/dev/null && break
        sleep 0.1
      done
      printf '%s\\n%s\\n' \\
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \\
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"analyze_repository","arguments":{"url":"https://github.com/o/r"}}}' \\
        | LEI_API_KEY=stub LEI_BASE_URL=http://127.0.0.1:#{port} python3 #{@server} 2>/dev/null
      kill $STUB_PID 2>/dev/null
      """

      {out, _} = System.cmd("bash", ["-c", script], cd: @root, stderr_to_stdout: false)

      out
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["id"] == 2))
    end

    @errored ~s({"report":{"repos":[{"header":{"repo":"https://github.com/o/r"},"data":{"repo":"https://github.com/o/r","risk":"undetermined","error":"Unable to analyze the repo, is this a valid Git repo URL?"}}]}})

    @determined ~s({"report":{"repos":[{"header":{"repo":"https://github.com/o/r"},"data":{"repo":"https://github.com/o/r","risk":"low","git":{"last_commit_date":"2026-09-01T00:00:00Z"},"results":{"contributor_count":9}}}]}})

    test "the reason is rendered, not dropped" do
      reply = against_stub(@errored)
      text = reply["result"]["content"] |> Enum.map_join(" ", & &1["text"])

      assert text =~ "Unable to analyze the repo",
             "the reason the repository was not analysed is dropped:\n#{text}"

      assert text =~ "not analysed",
             "an unanalysable repository is not marked as one:\n#{text}"
    end

    test "an answer where nothing was determined is an error to the agent" do
      reply = against_stub(@errored)

      assert reply["result"]["isError"] == true,
             "a wholly undetermined result came back as success, so the agent reads it as a finding"
    end

    test "a determined report is not an error, and carries the facts" do
      reply = against_stub(@determined)
      text = reply["result"]["content"] |> Enum.map_join(" ", & &1["text"])

      assert reply["result"]["isError"] == false
      assert text =~ "2026-09-01", "the last commit date is not rendered:\n#{text}"
      assert text =~ "9", "the contributor count is not rendered:\n#{text}"
    end
  end

  test "it has no third-party imports" do
    # The subject of this tool is dependency risk. Asking someone to install a
    # package tree to run it would be a poor advertisement, and one file with
    # nothing but the standard library can be read before it is trusted.
    source = File.read!(Path.join(@root, @server))

    imports =
      Regex.scan(~r/^\s*(?:import|from)\s+([a-zA-Z0-9_\.]+)/m, source)
      |> Enum.map(fn [_, m] -> m |> String.split(".") |> hd() end)
      |> Enum.uniq()

    stdlib = ~w(json os sys urllib http socket textwrap typing dataclasses argparse re time)

    assert Enum.all?(imports, &(&1 in stdlib)),
           "third-party imports: #{inspect(imports -- stdlib)}"
  end
end
