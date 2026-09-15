defmodule ReportConfigLeakTest do
  @moduledoc """
  An analysis report publishes the scoring thresholds it was scored with, and
  nothing else from the application environment.

  Reports embedded `Application.get_all_env(:lowendinsight)` with only
  `:jobs_per_core_max` removed, so any value an application configured under
  `:lowendinsight` -- a token, a key, a password, a URL with credentials --
  was published in every report it produced.
  """
  use ExUnit.Case, async: false

  @planted_secret "sk_live_PLANTED_DO_NOT_PUBLISH_0123456789"

  setup do
    Application.put_env(:lowendinsight, :some_api_token, @planted_secret)
    Application.put_env(:lowendinsight, :a_setting_added_later, "PLANTED_FUTURE_VALUE")

    on_exit(fn ->
      Application.delete_env(:lowendinsight, :some_api_token)
      Application.delete_env(:lowendinsight, :a_setting_added_later)
    end)
  end

  test "a report of a real analysis publishes no configured secret" do
    {:ok, cwd} = File.cwd()
    {:ok, report} = AnalyzerModule.analyze("file:///#{cwd}", "leak_test", %{types: false})

    encoded = Poison.encode!(report)

    refute encoded =~ @planted_secret
    refute encoded =~ "some_api_token"
    refute encoded =~ "PLANTED_FUTURE_VALUE"
  end

  test "the published config is only scoring thresholds" do
    {:ok, cwd} = File.cwd()
    {:ok, report} = AnalyzerModule.analyze("file:///#{cwd}", "leak_test", %{types: false})

    config = report[:data][:config]
    assert is_map(config)
    assert map_size(config) > 0, "thresholds should still be published"

    for key <- Map.keys(config) do
      assert key |> to_string() |> String.ends_with?("_level"),
             "#{inspect(key)} is not a scoring threshold"
    end
  end
end
