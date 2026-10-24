defmodule LeiService.OpenApiVersionTest do
  @moduledoc """
  `/openapi.json` describes the service that is running.

  The specification was a static file that said `"version": "0.9.2"` through
  seven releases of the service. A client generated from it, or a person
  reading `/doc`, had no way to know which API they were looking at -- or that
  it was a beta whose paths may still change.
  """
  use ExUnit.Case, async: false
  import Plug.Test

  @opts LeiService.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  defp spec do
    conn = conn(:get, "/openapi.json") |> LeiService.Endpoint.call(@opts)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp running_version, do: Application.spec(:lei_service, :vsn) |> to_string()

  test "info.version is the running service's version" do
    assert spec()["info"]["version"] == running_version()
  end

  test "a pre-release says it is a beta" do
    info = spec()["info"]

    if String.contains?(running_version(), "-") do
      assert info["description"] =~ ~r/\bbeta\b/i,
             "#{running_version()} is a pre-release and the specification does not say so"
    end
  end
end
