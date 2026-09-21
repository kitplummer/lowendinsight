defmodule Lei.ManifestGraphTest do
  @moduledoc """
  Which dependencies were chosen, and which arrived with them (#263).

  The issue originally proposed ranking by in-degree. Measured against this
  repository's own 62 dependencies that is anti-correlated with what it was
  after: `jason` and `telemetry` top the in-degree list and are both healthy,
  while all seven packages filed as issues have in-degree **zero**.

  In-degree describes how much other dependencies rely on a package. What
  mattered about `git_cli` is that *we* rely on it, which no dependency graph
  contains — and in-degree zero is exactly how that shows up.
  """
  use ExUnit.Case, async: true

  alias Lei.ManifestGraph

  describe "classifying a complete graph" do
    setup do
      # b and c arrived with a; d was chosen.
      packages = ["a", "b", "c", "d"]
      edges = %{"a" => ["b", "c"], "b" => ["c"], "c" => [], "d" => []}

      %{result: ManifestGraph.classify(packages, edges)}
    end

    test "a package nothing depends on is direct", %{result: result} do
      assert result["a"].direct == true
      assert result["d"].direct == true
    end

    test "a package something depends on is transitive", %{result: result} do
      assert result["b"].direct == false
      assert result["c"].direct == false
    end

    test "in-degree counts only what is in the manifest", %{result: result} do
      assert result["c"].in_degree == 2
      assert result["b"].in_degree == 1
      assert result["a"].in_degree == 0
    end

    test "an edge pointing outside the manifest is not counted" do
      # A dependency on something the customer does not have says nothing
      # about their tree.
      result = ManifestGraph.classify(["a"], %{"a" => ["not-in-this-manifest"]})

      assert result["a"].direct == true
      assert result["a"].in_degree == 0
    end
  end

  describe "when some edges cannot be read" do
    # An unsupported ecosystem, or a registry that did not answer.
    test "a package nothing points at is unknown, not direct" do
      # Something unreadable might have depended on it. Claiming direct would
      # be asserting more than was measured.
      result = ManifestGraph.classify(["a", "b"], %{"a" => nil, "b" => []})

      assert result["b"].direct == nil
      assert result["b"].in_degree == nil
    end

    test "unknown is never reported as transitive" do
      # The failure this avoids: marking it false quietly demotes exactly the
      # packages we know least about, and a consumer filtering for "critical
      # and direct" would never see them.
      result = ManifestGraph.classify(["a", "b"], %{"a" => nil, "b" => []})

      refute result["b"].direct == false
    end

    test "a package something does depend on is still knowable" do
      # Incompleteness elsewhere cannot make an observed edge disappear.
      result = ManifestGraph.classify(["a", "b", "c"], %{"a" => ["b"], "b" => [], "c" => nil})

      assert result["b"].direct == false
      assert result["b"].in_degree == 1
    end
  end

  describe "shapes that must not produce a confident answer" do
    test "an empty manifest classifies nothing" do
      assert ManifestGraph.classify([], %{}) == %{}
    end

    test "no edges at all makes everything unknown, not everything direct" do
      # A scan where no registry answered would otherwise report every
      # dependency as a deliberate choice.
      result = ManifestGraph.classify(["a", "b"], %{})

      assert result["a"].direct == nil
      assert result["b"].direct == nil
    end

    test "anything that is not a list of packages yields nothing" do
      assert ManifestGraph.classify(nil, %{}) == %{}
      assert ManifestGraph.classify(["a"], nil) == %{}
    end
  end

  describe "the measurement that reframed this" do
    test "a healthy hub and an abandoned leaf are told apart correctly" do
      # jason had in-degree 6 and is actively maintained; git_cli had
      # in-degree 0 and had not been touched in seven years. Ranking by
      # in-degree would have put the hub first.
      packages = ["jason", "git_cli", "app_dep_a", "app_dep_b"]

      edges = %{
        "jason" => [],
        "git_cli" => [],
        "app_dep_a" => ["jason"],
        "app_dep_b" => ["jason"]
      }

      result = ManifestGraph.classify(packages, edges)

      assert result["jason"].in_degree == 2
      assert result["jason"].direct == false

      assert result["git_cli"].in_degree == 0

      assert result["git_cli"].direct == true,
             "the dependency that needed attention was not marked as one the customer chose"
    end
  end
end
