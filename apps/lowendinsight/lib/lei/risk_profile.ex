defmodule Lei.RiskProfile do
  @moduledoc """
  The distribution a report's verdict was collapsed from (#247).

  `data.risk` is the worst of a repository's metrics. That makes two very
  different repositories read identically:

      one functional contributor, active this month   -> "critical"
      one functional contributor, silent two years    -> "critical"

  The first is a bus-factor bet on a project someone is working on. The second
  is an abandoned dependency. `max/1` is the operation that loses the
  difference, and it loses it after every threshold has already been applied,
  so no amount of retuning reaches it.

  Nor does a level above `critical`: the scale saturates exactly where
  compounding matters most, and a fifth level would break every consumer of the
  enum -- `scripts/canary.sh`, `scripts/library-isolation.sh`, the SARIF
  mapping, and any customer gate.

  So the verdict is left alone and the distribution reported beside it. No
  weights, no 0-100 score, no normalisation: a weighted score needs weights,
  and deciding whether bus factor outranks currency is a judgement there is no
  evidence for. Counts need none, and they are enough to order 200 `critical`
  dependencies by how much is wrong with each.
  """

  @levels ~w(low medium high critical)
  @elevated ~w(high critical)

  @doc """
  Builds the profile from a results map.

  Works on atom-keyed results as the analyzer holds them and string-keyed ones
  as they come back from JSON, because it matches on the *values* -- the risk
  words themselves -- rather than on which keys are supposed to carry them.
  That also means a field whose value is not a risk level is skipped rather
  than counted: `agentic_classification` reads "human", "mixed" or "agent",
  and is not a verdict about risk.

  Metric names in `elevated` are returned as strings and sorted, so the field
  is stable between two reports of the same repository.
  """
  @spec of(map) :: map
  def of(results) when is_map(results) do
    # No `value in @levels` filter here: the counting below matches each level
    # by name and `elevated` matches high and critical by name, so a field
    # reading "human" is excluded by both without help. A clause that changes
    # no output is one nothing can test, and it would read as a safeguard.
    scored =
      for {key, value} <- results, is_binary(value) do
        {to_string(key), value}
      end

    %{
      "counts" =>
        Map.new(@levels, fn level ->
          {level, Enum.count(scored, fn {_, value} -> value == level end)}
        end),
      "elevated" =>
        scored
        |> Enum.filter(fn {_, value} -> value in @elevated end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()
    }
  end

  def of(_), do: %{"counts" => Map.new(@levels, &{&1, 0}), "elevated" => []}
end
