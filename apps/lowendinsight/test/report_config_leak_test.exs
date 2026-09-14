defmodule ReportConfigLeakTest do
  @moduledoc """
  An analysis report never carries application secrets (security, 2026-09-14).

  Every report embedded the whole `:lowendinsight` application env as
  `data.config`. As the app grew payment and session config, that came to
  include the Stripe secret key, the webhook signing secret, the session
  secret and the JWT secret -- published in every API response, every cached
  report, the Try It page, the GitHub trending pages and the cache export.

  The filter was a denylist, which fails open for every key added after it was
  written. Reports now carry an allowlist: the risk thresholds that explain how
  the report was scored, and nothing else.
  """
  use ExUnit.Case, async: false

  @planted [
    stripe_secret_key: "sk_test_PLANTEDSECRETVALUE0000000000",
    stripe_webhook_secret: "whsec_PLANTEDSECRETVALUE000000",
    session_secret_key_base: "PLANTED_SESSION_SECRET_BASE",
    jwt_secret: "PLANTED_JWT_SECRET",
    some_future_api_token: "PLANTED_FUTURE_TOKEN"
  ]

  setup do
    saved = for {k, _} <- @planted, do: {k, Application.fetch_env(:lowendinsight, k)}
    for {k, v} <- @planted, do: Application.put_env(:lowendinsight, k, v)

    on_exit(fn ->
      for {k, v} <- saved do
        case v do
          {:ok, value} -> Application.put_env(:lowendinsight, k, value)
          :error -> Application.delete_env(:lowendinsight, k)
        end
      end
    end)

    dir = Path.join(System.tmp_dir!(), "lei_leak_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    env = [
      {"GIT_AUTHOR_NAME", "T"},
      {"GIT_AUTHOR_EMAIL", "t@example.com"},
      {"GIT_COMMITTER_NAME", "T"},
      {"GIT_COMMITTER_EMAIL", "t@example.com"}
    ]

    System.cmd("git", ["init", "-q"], cd: dir)
    File.write!(Path.join(dir, "README.md"), "# t\n")
    System.cmd("git", ["add", "."], cd: dir)
    System.cmd("git", ["commit", "-q", "-m", "init"], cd: dir, env: env)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  test "no planted secret appears anywhere in an encoded report", %{dir: dir} do
    {:ok, report} = AnalyzerModule.analyze("file://" <> dir, "leak-test", %{types: false})
    encoded = Poison.encode!(report)

    for {key, value} <- @planted do
      refute encoded =~ value, "report contains the value of #{key}"
      refute encoded =~ Atom.to_string(key), "report names #{key}"
    end
  end

  test "report config carries only the scoring thresholds", %{dir: dir} do
    {:ok, report} = AnalyzerModule.analyze("file://" <> dir, "leak-test", %{types: false})
    keys = report.data.config |> Map.keys() |> Enum.map(&to_string/1)

    assert "critical_contributor_level" in keys
    assert "medium_currency_level" in keys
    assert "sbom_risk_level" in keys

    for key <- keys do
      assert key == "sbom_risk_level" or String.ends_with?(key, "_level"),
             "unexpected config key in report: #{key}"
    end
  end

  test "an unknown future key is not published, even if harmless-looking" do
    config = Helpers.report_config(critical_currency_level: 104, brand_new_setting: "anything")

    assert config[:critical_currency_level] == 104
    refute Map.has_key?(config, :brand_new_setting)
  end
end
