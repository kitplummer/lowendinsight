defmodule Lei.ManifestGraph do
  @moduledoc """
  Which dependencies a customer chose, and which arrived with them (#263).

  `risk_rank` orders a manifest by how sick each dependency is. It cannot say
  whether the customer can do anything about it, and those are different
  questions: a direct dependency was chosen and can be replaced, while a
  transitive one may not be controllable without upstream moving.

  ## Why not in-degree

  This issue originally proposed ranking by in-degree as a blast-radius proxy.
  Measured against this repository's own 62 dependencies, that is
  **anti-correlated** with what it was meant to find:

      highest in-degree:  jason 6 · telemetry 6 · decimal 5

      the seven filed as issues (#250-#254):
        git_cli, elixir_uuid, yarn_parser, poison, temp, mix_audit, json_xema
        -> in-degree 0, every one

  In-degree measures how much other *dependencies* rely on a package, not how
  much the *customer's code* does. `git_cli` is on every analysis path in the
  product and nothing in the tree depends on it, because we do -- a
  relationship no dependency graph contains.

  What the measurement did show is that in-degree zero means direct, which is
  the signal that made `git_cli` matter. Health says what is wrong;
  directness says whether they can act on it.

  In-degree is still reported, because it is real information about blast
  radius within the tree. Neither is folded into the rank: both are facts
  beside it, and the consumer's question decides which matters.
  """

  @typedoc "A package identified as the manifest identifies it."
  @type name :: String.t()

  @doc """
  Directness and in-degree for every package in a manifest.

  `edges` maps a package to the packages it declares a dependency on. Only
  edges pointing at packages **in this manifest** count: a dependency on
  something the customer does not have says nothing about their tree.

  Returns a map of package to `%{direct: boolean | nil, in_degree: non_neg_integer | nil}`.

  A package with no edges known -- an unsupported ecosystem, a registry that
  did not answer -- gets `nil` for both. **Unknown is not transitive.** Marking
  it `direct: false` would quietly demote exactly the packages we know least
  about, and a consumer filtering for "critical and direct" would never see
  them.
  """
  @spec classify([name], %{optional(name) => [name] | nil}) :: %{
          optional(name) => %{direct: boolean | nil, in_degree: non_neg_integer | nil}
        }
  def classify(packages, edges) when is_list(packages) and is_map(edges) do
    counts =
      edges
      |> Enum.reduce(%{}, fn
        {_from, deps}, acc when is_list(deps) ->
          # Edges pointing outside the manifest are counted here and never
          # read: the result is built over `packages` alone, so only names in
          # the manifest are ever looked up. Filtering first changed no output
          # and read as a safeguard, which is worse than not having one.
          Enum.reduce(deps, acc, fn dep, inner -> Map.update(inner, dep, 1, &(&1 + 1)) end)

        {_from, _unknown}, acc ->
          acc
      end)

    # Whether *this* package's edges are known decides whether we can speak
    # about it. A package nothing points at is direct only if the packages
    # that could have pointed at it were all readable.
    edges_complete? =
      Enum.all?(packages, fn p -> is_list(Map.get(edges, p)) end)

    Map.new(packages, fn package ->
      in_degree = Map.get(counts, package, 0)

      classification =
        cond do
          # Something in the manifest depends on it: transitive, and knowable
          # regardless of what else failed to resolve.
          in_degree > 0 -> %{direct: false, in_degree: in_degree}
          # Nothing points at it, but the graph is incomplete -- something
          # unreadable might have. Say so rather than guess.
          not edges_complete? -> %{direct: nil, in_degree: nil}
          true -> %{direct: true, in_degree: 0}
        end

      {package, classification}
    end)
  end

  def classify(_packages, _edges), do: %{}
end
