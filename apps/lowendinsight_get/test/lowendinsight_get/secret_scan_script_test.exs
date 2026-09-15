defmodule LowendinsightGet.SecretScanScriptTest do
  @moduledoc """
  scripts/secret-scan.sh is what the canary and the monitor run over every
  public body they fetch, so what it catches and what it lets through are
  tested here, where CI runs them.

  Analysis reports published the application environment -- the Stripe secret
  key, the webhook signing secret and two signing secrets -- on public pages
  for months while every check was green (security, 2026-09-14). Nothing
  looked at what the deployment actually served.
  """
  use ExUnit.Case, async: true

  import Plug.Test

  @script Path.expand("../../../../scripts/secret-scan.sh", __DIR__)

  defp scan(body) do
    # Through a file on stdin: System.cmd has no stdin argument, and a shell
    # heredoc would itself need the value quoted.
    path = Path.join(System.tmp_dir!(), "secret-scan-#{System.unique_integer([:positive])}")
    File.write!(path, body)

    try do
      System.cmd("bash", ["-c", ~s(#{@script} "test body" < "$1"), "scan", path],
        stderr_to_stdout: true
      )
    after
      File.rm(path)
    end
  end

  defp filler(n), do: String.duplicate("A1b2", n)

  test "the script exists and is executable" do
    assert File.exists?(@script)
    assert File.stat!(@script).mode |> Bitwise.band(0o111) != 0
  end

  test "an empty body is not a clean scan" do
    assert {_, 2} = scan("")
    assert {_, 2} = scan("  \n\t ")
  end

  describe "finds, and never prints what it found" do
    for {name, value} <- [
          {"stripe secret key", "sk_test_" <> String.duplicate("A1b2", 6)},
          {"stripe secret key", "rk_live_" <> String.duplicate("A1b2", 6)},
          {"stripe webhook secret", "whsec_" <> String.duplicate("A1b2", 6)},
          {"lei api key", "lei_" <> String.duplicate("0a1b", 8)},
          {"lei recovery code", "lei_recover_" <> String.duplicate("0a1b", 6)},
          {"github token", "ghp_" <> String.duplicate("A1b2", 9)},
          {"aws access key", "AKIA" <> String.duplicate("ABCD", 4)},
          {"private key", "-----BEGIN RSA PRIVATE KEY-----"},
          {"jwt", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.c2lnbmF0dXJlLXZhbHVl"},
          {"database url with password", "postgres://lei:hunter2hunter2@db.internal:5432/lei"},
          {"redis url with password", "redis://default:hunter2hunter2@redis.internal:6379"}
        ] do
      test "#{name}: #{String.slice(value, 0, 12)}..." do
        {output, status} =
          scan(~s(<html><body><pre>config: "#{unquote(value)}"</pre></body></html>))

        assert status == 1
        assert output =~ unquote(name)
        # CI logs are the one place a found secret must not be repeated.
        refute output =~ unquote(value)
      end
    end
  end

  test "the report shape that leaked on 2026-09-14 is found" do
    leaked =
      Poison.encode!(%{
        data: %{
          repo: "https://github.com/example/repo",
          config: %{
            critical_contributor_level: 2,
            stripe_secret_key: "sk_test_" <> filler(6),
            stripe_webhook_secret: "whsec_" <> filler(6),
            session_secret_key_base: filler(20)
          }
        }
      })

    {output, 1} = scan(leaked)
    assert output =~ "stripe secret key"
    assert output =~ "secret setting name"
  end

  test "a setting name alone, with a value that is not secret-shaped, is found" do
    # A future secret's value may match no pattern; its key name still says
    # configuration is being published.
    {output, 1} = scan(~s({"data":{"config":{"jwt_secret":"short"}}}))
    assert output =~ "secret setting name"
  end

  describe "does not cry wolf on what the service serves" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
      :ok
    end

    @opts LowendinsightGet.Endpoint.init([])

    for path <- [
          "/",
          "/llms.txt",
          "/doc",
          "/openapi.json",
          "/gh_trending",
          "/gh_trending/elixir",
          "/signup",
          "/login"
        ] do
      test "GET #{path}" do
        conn = conn(:get, unquote(path)) |> LowendinsightGet.Endpoint.call(@opts)
        assert conn.status == 200, "#{unquote(path)} answered #{conn.status}"
        assert {_, 0} = scan(conn.resp_body)
      end
    end

    test "a real analysis report of a local repository" do
      {:ok, report} =
        AnalyzerModule.analyze("file:///" <> File.cwd!(), "secret_scan_test", %{types: false})

      assert {_, 0} = scan(Poison.encode!(report))
    end
  end
end
