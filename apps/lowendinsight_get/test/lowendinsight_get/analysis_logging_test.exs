defmodule LowendinsightGet.AnalysisLoggingTest do
  @moduledoc """
  Production logs at :info do not name the repositories analysed (#149).

  The worker's info lines carried no identity, but they carried the URLs, and
  a log line's timestamp sits next to a ledger entry's. Anyone with both could
  put a paying wallet beside what it analysed -- the link the request log was
  changed to stop making.
  """
  use ExUnit.Case, async: false

  require Logger

  setup do
    # Test config logs at :error, where an info line carrying a URL would never
    # be emitted and a refute would pass by examining nothing.
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  test "analysing a repository does not log its URL at info" do
    url = "https://github.com/kitplummer/logging-privacy-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    # Cached, so the worker runs without cloning anything.
    LowendinsightGet.Datastore.write_to_cache(url, %{
      data: %{repo: url},
      header: %{end_time: now, start_time: now, uuid: "logging-privacy"}
    })

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        LowendinsightGet.Analysis.process(UUID.uuid1(), [url], DateTime.utc_now())
      end)

    # The worker did log at info; the question is what.
    assert log =~ "[info]"
    refute log =~ url
  end
end
