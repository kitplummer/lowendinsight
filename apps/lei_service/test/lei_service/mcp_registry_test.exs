defmodule LeiService.McpRegistryTest do
  @moduledoc """
  `server.json`: the listing `mcp-publisher` sends to the MCP Registry.

  The registry checks who owns the name, not what the listing says about the
  server. A listing naming a version this service no longer runs, a URL it
  does not serve, or no credential when every call needs one is published
  as readily as a correct one -- and a client configured from it fails at its
  first request, far from here. So the listing is held to the server.
  """
  use ExUnit.Case, async: true

  @listing Path.expand("../../../../server.json", __DIR__)

  defp listing, do: @listing |> File.read!() |> Jason.decode!()

  test "the version is the release" do
    assert listing()["version"] == to_string(Application.spec(:lei_service, :vsn))
  end

  test "it lists the remote this service serves, over the transport it speaks" do
    assert [remote] = listing()["remotes"]
    assert remote["type"] == "streamable-http"
    assert remote["url"] == "https://lowendinsight.dev/mcp"
  end

  test "it says a key is required, and that it is a secret" do
    [remote] = listing()["remotes"]

    assert [header] = remote["headers"]
    assert header["name"] == "Authorization"
    assert header["isRequired"] == true
    assert header["isSecret"] == true
  end

  test "it names the schema it was written against" do
    assert listing()["$schema"] =~
             ~r"^https://static\.modelcontextprotocol\.io/schemas/\d{4}-\d{2}-\d{2}/server\.schema\.json$"
  end
end
