defmodule LibraryEnvTest do
  @moduledoc """
  The library's application environment holds analyzer settings only.

  The hosted service's settings -- Stripe keys, signing secrets, Tempo, pricing,
  rate limits -- used to live under `:lowendinsight`, and reports once
  published that whole environment (security, 2026-09-14). They now live under
  `:lei_service` (ADR-003). A service setting added here again fails this test,
  in the test configuration and in production's runtime.exs.
  """
  use ExUnit.Case, async: false

  @analyzer_settings MapSet.new([
                       :sbom_risk_level,
                       :critical_contributor_level,
                       :high_contributor_level,
                       :medium_contributor_level,
                       :critical_currency_level,
                       :high_currency_level,
                       :medium_currency_level,
                       :critical_functional_currency_level,
                       :high_functional_currency_level,
                       :medium_functional_currency_level,
                       :critical_large_commit_level,
                       :high_large_commit_level,
                       :medium_large_commit_level,
                       :critical_functional_contributors_level,
                       :high_functional_contributors_level,
                       :medium_functional_contributors_level,
                       :critical_agentic_level,
                       :high_agentic_level,
                       :medium_agentic_level,
                       :jobs_per_core_max,
                       :base_temp_dir,
                       :cache_dir,
                       :airgapped_mode
                     ])

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)

  defp non_analyzer(keys), do: Enum.reject(keys, &MapSet.member?(@analyzer_settings, &1))

  test "the loaded configuration puts nothing but analyzer settings under :lowendinsight" do
    keys = Application.get_all_env(:lowendinsight) |> Keyword.keys()

    assert keys != [], "no :lowendinsight settings loaded; the check would be vacuous"
    assert non_analyzer(keys) == []
  end

  test "production's runtime configuration does the same" do
    env = %{
      "LEI_JWT_SECRET" => "library-env-test-jwt",
      "LEI_SESSION_SECRET" => String.duplicate("s", 88),
      "DATABASE_URL" => "ecto://u:p@localhost/db",
      "STRIPE_SECRET_KEY" => "sk_test_" <> String.duplicate("x", 24)
    }

    saved = for {k, _} <- env, into: %{}, do: {k, System.get_env(k)}
    for {k, v} <- env, do: System.put_env(k, v)

    try do
      config = Config.Reader.read!(@runtime, env: :prod, target: :host)
      keys = Keyword.keys(config[:lowendinsight] || [])

      assert keys != []
      assert non_analyzer(keys) == []
      assert Keyword.has_key?(config[:lei_service], :stripe_secret_key)
    after
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end
  end
end
