defmodule LowendinsightGet.PageScriptContractTest do
  use ExUnit.Case, async: true

  @moduledoc """
  endpoints.js drives the only interactive control on the site, and it reaches
  the page through element ids. Nothing checks that the ids it asks for exist.

  They did not. The script was written against the report page's markup, which
  has an analyze-button and an invalid-url span; the landing page's form has
  neither. `disable_button` did `null.classList.add(...)`, and because
  `validate_and_submit` calls `preventDefault` first, the throw left the form
  never submitting. Clicking Analyze did nothing, with the reason visible only
  in the browser console.

  Server-side everything looked correct: the template rendered, the asset
  returned 200, and the route worked when called directly.
  """

  @js_path "priv/static/js/endpoints.js"
  @templates %{
    "analyze.html.eex" => "priv/templates/analyze.html.eex",
    "analysis.html.eex" => "priv/templates/analysis.html.eex"
  }

  # Ids used by the submit path: the form, its input, the button's loading
  # state and the error message. `repo` is deliberately absent -- it belongs to
  # the results table, which only the report page has.
  @submit_path_ids ~w(form input-url analyze-button invalid-url)

  defp read(path), do: File.read!(Path.join(File.cwd!(), path))

  defp ids_referenced_by_script do
    read(@js_path)
    # Matches both the direct call and the el/1 helper the script wraps it in.
    # The first version of this scan only knew about getElementById and found
    # one id after that refactor -- which the vacuity test above caught.
    |> then(&Regex.scan(~r/(?:getElementById|\bel)\("([^"]+)"\)/, &1))
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp ids_in(template) do
    read(@templates[template])
    |> then(&Regex.scan(~r/id="([^"]+)"/, &1))
    |> Enum.map(fn [_, id] -> id end)
    |> MapSet.new()
  end

  test "the script actually references ids" do
    # A regex that matched nothing would make every assertion below vacuous --
    # the same shape of failure these tests exist to catch.
    ids = ids_referenced_by_script()

    assert length(ids) >= 4, "found #{length(ids)} ids in #{@js_path}; the scan looks broken"
  end

  test "the landing page has every id the submit path needs" do
    present = ids_in("analyze.html.eex")

    missing = Enum.reject(@submit_path_ids, &MapSet.member?(present, &1))

    assert missing == [],
           """
           analyze.html.eex is missing #{inspect(missing)}.

           endpoints.js reaches these by id. A missing one is not a degraded
           page -- disable_button throws on null, and validate_and_submit has
           already called preventDefault, so the form never submits and the
           button does nothing at all.
           """
  end

  test "the report page has every id the submit path needs" do
    present = ids_in("analysis.html.eex")

    missing = Enum.reject(@submit_path_ids, &MapSet.member?(present, &1))

    assert missing == [], "analysis.html.eex is missing #{inspect(missing)}"
  end

  test "every id the script uses exists on some page it runs on" do
    # Catches the reverse: a script reaching for something no template provides.
    everywhere =
      @templates
      |> Map.keys()
      |> Enum.map(&ids_in/1)
      |> Enum.reduce(&MapSet.union/2)

    orphans = Enum.reject(ids_referenced_by_script(), &MapSet.member?(everywhere, &1))

    assert orphans == [],
           "endpoints.js references #{inspect(orphans)}, which no template defines"
  end

  test "ids are unique within a page" do
    # getElementById returns the first match, so a duplicate id silently wires
    # the script to the wrong element.
    for {name, path} <- @templates do
      ids =
        read(path)
        |> then(&Regex.scan(~r/id="([^"]+)"/, &1))
        |> Enum.map(fn [_, id] -> id end)

      duplicates = ids -- Enum.uniq(ids)

      assert duplicates == [], "#{name} defines #{inspect(duplicates)} more than once"
    end
  end

  test "the form submits through the handler and passes the event" do
    # onsubmit must return the handler's value, or the browser submits natively
    # and the validation is skipped. The event is passed rather than read off
    # the window global.
    for {name, path} <- @templates do
      source = read(path)

      expected = "onsubmit=\"return validate_and_submit(event)\""

      assert String.contains?(source, expected),
             "#{name} does not call validate_and_submit(event) and return its result"
    end
  end
end
