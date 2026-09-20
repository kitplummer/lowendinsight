defmodule Lei.RiskProfileTest do
  @moduledoc """
  What the verdict was collapsed from (#247).

  `data.risk` is a maximum, so a repository with one critical metric and one
  with three read the same. The case that prompted this: a single-maintainer
  project under active development and a single-maintainer project abandoned
  two years ago are both `critical`, and one is a bet while the other is a
  dead dependency.

  The profile carries the difference without touching the enum, which
  `scripts/canary.sh` and `scripts/library-isolation.sh` both match on.
  """
  use ExUnit.Case, async: true

  alias Lei.RiskProfile

  describe "the case the maximum cannot express" do
    test "two critical metrics are distinguishable from one" do
      bet = RiskProfile.of(%{"functional_contributors_risk" => "critical", "b" => "low"})

      abandoned =
        RiskProfile.of(%{
          "functional_contributors_risk" => "critical",
          "functional_commit_currency_risk" => "critical"
        })

      # Both repositories report risk "critical". Only the profile separates them.
      assert bet["counts"]["critical"] == 1
      assert abandoned["counts"]["critical"] == 2
      refute bet == abandoned
    end

    test "elevated names the metrics that are wrong, not just how many" do
      profile =
        RiskProfile.of(%{
          "functional_contributors_risk" => "critical",
          "functional_commit_currency_risk" => "high",
          "sbom_risk" => "medium",
          "large_recent_commit_risk" => "low"
        })

      assert profile["elevated"] == [
               "functional_commit_currency_risk",
               "functional_contributors_risk"
             ]
    end
  end

  describe "what counts as a verdict" do
    test "a field whose value is not a risk level is not counted as one" do
      # agentic_classification reads human/mixed/agent. It is a description,
      # not a verdict, and counting it would inflate every profile.
      profile =
        RiskProfile.of(%{
          "agentic_classification" => "human",
          "contributor_risk" => "low"
        })

      assert profile["counts"] == %{"low" => 1, "medium" => 0, "high" => 0, "critical" => 0}
    end

    test "numbers, lists and nil are ignored" do
      profile =
        RiskProfile.of(%{
          "contributor_count" => 12,
          "top10_contributors" => [%{"name" => "Ada"}],
          "recent_commit_size_in_percent_of_codebase" => 0.0128,
          "functional_commit_currency_risk" => nil,
          "sbom_risk" => "high"
        })

      assert profile["counts"]["high"] == 1
      assert profile["elevated"] == ["sbom_risk"]
    end

    test "atom keys and string keys give the same answer" do
      atoms = RiskProfile.of(%{contributor_risk: "high", sbom_risk: "low"})
      strings = RiskProfile.of(%{"contributor_risk" => "high", "sbom_risk" => "low"})

      assert atoms == strings
    end
  end

  describe "empty and absent" do
    # A profile over nothing must not read as a healthy repository. Every level
    # is present and zero, and `elevated` is empty, so a consumer can tell
    # "nothing was wrong" from "nothing was measured" by the counts summing to
    # zero rather than by a missing key.
    test "no results yields zeroes, not a low verdict" do
      profile = RiskProfile.of(%{})

      assert profile["counts"] == %{"low" => 0, "medium" => 0, "high" => 0, "critical" => 0}
      assert profile["elevated"] == []
    end

    test "something that is not a map at all" do
      assert RiskProfile.of(nil)["counts"]["critical"] == 0
    end
  end

  describe "it is stable" do
    test "elevated is sorted, so two reports of one repository compare equal" do
      a = RiskProfile.of(%{"z_risk" => "high", "a_risk" => "critical"})
      b = RiskProfile.of(%{"a_risk" => "critical", "z_risk" => "high"})

      assert a["elevated"] == ["a_risk", "z_risk"]
      assert a == b
    end
  end
end
