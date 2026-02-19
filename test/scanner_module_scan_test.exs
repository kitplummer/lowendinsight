# Tests for ScannerModule.scan/1 with a minimal project (no network needed)

defmodule ScannerModuleScanTest do
  use ExUnit.Case, async: false

  @minimal_mix_exs """
  defmodule MinimalTest.MixProject do
    use Mix.Project

    def project do
      [app: :minimal_test, version: "0.1.0", deps: deps()]
    end

    defp deps do
      []
    end
  end
  """

  @empty_lockfile "%{}"

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "lei_scan_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    File.write!(Path.join(tmp_dir, "mix.exs"), @minimal_mix_exs)
    File.write!(Path.join(tmp_dir, "mix.lock"), @empty_lockfile)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "scan/1 scans a minimal mix project without network", %{tmp_dir: tmp_dir} do
    json = ScannerModule.scan(tmp_dir)
    assert is_binary(json)

    decoded = Poison.decode!(json)
    assert decoded["state"] == "complete"
    assert decoded["metadata"]["dependency_count"] == 0
    assert decoded["metadata"]["repo_count"] == 0
  end

  test "scan/1 includes timing metadata", %{tmp_dir: tmp_dir} do
    json = ScannerModule.scan(tmp_dir)
    decoded = Poison.decode!(json)

    assert Map.has_key?(decoded["metadata"], "times")
    assert Map.has_key?(decoded["metadata"]["times"], "start_time")
    assert Map.has_key?(decoded["metadata"]["times"], "end_time")
    assert Map.has_key?(decoded["metadata"]["times"], "duration")
  end

  test "scan/1 identifies files present", %{tmp_dir: tmp_dir} do
    json = ScannerModule.scan(tmp_dir)
    decoded = Poison.decode!(json)

    # mix.exs and mix.lock should be detected
    assert is_list(decoded["files"])
  end
end
