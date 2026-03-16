defmodule AnalyzerModuleTest do
  use ExUnit.Case, async: false

  describe "agentic_classification in results" do
    test "analysis includes agentic_classification field with valid label" do
      {:ok, cwd} = File.cwd()

      {:ok, report} =
        AnalyzerModule.analyze(["file:///#{cwd}"], "test", DateTime.utc_now(), %{types: false})

      repo_data = List.first(report[:report][:repos])
      results = repo_data[:data][:results]

      assert Map.has_key?(results, :agentic_classification)
      assert results[:agentic_classification] in ["human", "mixed", "agent"]
    end

    test "agentic_classification reflects actual contribution ratio" do
      {:ok, cwd} = File.cwd()

      {:ok, report} =
        AnalyzerModule.analyze(["file:///#{cwd}"], "test", DateTime.utc_now(), %{types: false})

      repo_data = List.first(report[:report][:repos])
      results = repo_data[:data][:results]

      ratio = results[:agentic_contribution_ratio]

      expected_classification =
        cond do
          ratio > 0.7 -> "agent"
          ratio >= 0.3 -> "mixed"
          true -> "human"
        end

      assert results[:agentic_classification] == expected_classification
    end

    test "analysis includes agentic_contribution_ratio" do
      {:ok, cwd} = File.cwd()

      {:ok, report} =
        AnalyzerModule.analyze(["file:///#{cwd}"], "test", DateTime.utc_now(), %{types: false})

      repo_data = List.first(report[:report][:repos])
      results = repo_data[:data][:results]

      assert Map.has_key?(results, :agentic_contribution_ratio)
      ratio = results[:agentic_contribution_ratio]
      assert is_float(ratio) or is_integer(ratio)
      assert ratio >= 0.0 and ratio <= 1.0
    end

    test "analysis does not include agentic_risk field" do
      {:ok, cwd} = File.cwd()

      {:ok, report} =
        AnalyzerModule.analyze(["file:///#{cwd}"], "test", DateTime.utc_now(), %{types: false})

      repo_data = List.first(report[:report][:repos])
      results = repo_data[:data][:results]

      refute Map.has_key?(results, :agentic_risk)
    end
  end

  describe "restricted_contributors field" do
    test "restricted_contributors is nil when no github token configured" do
      {:ok, cwd} = File.cwd()

      {:ok, report} =
        AnalyzerModule.analyze(["file:///#{cwd}"], "test", DateTime.utc_now(), %{types: false})

      repo_data = List.first(report[:report][:repos])
      results = repo_data[:data][:results]

      assert Map.has_key?(results, :restricted_contributors)
      assert results[:restricted_contributors] == nil
    end
  end
end
