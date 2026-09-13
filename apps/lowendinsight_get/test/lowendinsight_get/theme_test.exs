defmodule LowendinsightGet.ThemeTest do
  use ExUnit.Case, async: true

  import Plug.Test

  @moduledoc """
  Dark mode is one set of tokens shared by every page. These check the parts
  that are easy to get subtly wrong and hard to notice: a page that misses the
  stylesheet, a theme that cannot be switched back, and colour pairs that stop
  being legible.
  """

  @get_templates Path.wildcard("priv/templates/*.html.eex")
  @lei_templates Path.wildcard("../lowendinsight/priv/templates/*.html.eex")
  @theme_css "priv/static/css/theme.css"

  defp read(p), do: File.read!(Path.join(File.cwd!(), p))

  # A full document starts with a doctype; the rest are partials rendered
  # inside layout.html.eex and inherit its head.
  defp documents do
    (@get_templates ++ @lei_templates)
    |> Enum.filter(fn p -> File.read!(Path.join(File.cwd!(), p)) =~ ~r/<!DOCTYPE/i end)
  end

  describe "coverage" do
    # Derived from what the site actually serves, not from a directory glob.
    #
    # The first version of these tests enumerated *.html.eex and passed while
    # /doc shipped unthemed -- it is a static file, not a template -- and while
    # the signup and login pages shipped without favicon links, because their
    # layout lives in the other app's directory. Both gaps reached production.
    @html_routes ["/", "/doc", "/signup", "/login"]

    defp render(path) do
      conn(:get, path)
      |> LowendinsightGet.Endpoint.call(LowendinsightGet.Endpoint.init([]))
    end

    test "the routes under test actually return HTML" do
      # If these stopped returning pages, every assertion below would pass by
      # examining nothing.
      for path <- @html_routes do
        conn = render(path)

        assert conn.status == 200, "#{path} returned #{conn.status}"
        assert conn.resp_body =~ ~r/<html/i, "#{path} did not return a document"
      end
    end

    test "every served page links the theme stylesheet" do
      missing = Enum.reject(@html_routes, &(render(&1).resp_body =~ "/css/theme.css"))

      assert missing == [],
             "these pages render without the theme and will stay light: #{inspect(missing)}"
    end

    test "every served page applies the stored theme before paint" do
      # A deferred script runs after first paint, so the page renders light and
      # then flips. The flash is worse than no dark mode.
      missing = Enum.reject(@html_routes, &(render(&1).resp_body =~ "lei-theme"))

      assert missing == [], "these pages will flash the wrong theme: #{inspect(missing)}"
    end

    test "every served page carries the toggle" do
      missing = Enum.reject(@html_routes, &(render(&1).resp_body =~ "theme-toggle"))

      assert missing == [], "no way to switch theme on: #{inspect(missing)}"
    end

    test "every served page carries the favicon links" do
      missing = Enum.reject(@html_routes, &(render(&1).resp_body =~ "rel=\"icon\""))

      assert missing == [], "these pages show a generic tab icon: #{inspect(missing)}"
    end

    test "no template carries a raw colour literal" do
      # Colours live in one place. A literal in a template is a colour that
      # cannot follow the theme.
      sources =
        Path.wildcard("priv/templates/*.html.eex") ++
          Path.wildcard("../lowendinsight/priv/templates/*.html.eex") ++
          ["priv/static/index.html"]

      offenders =
        for p <- sources,
            body = read(p),
            literals = Regex.scan(~r/:\s*(#[0-9a-fA-F]{3,6})\b/, body),
            literals != [],
            do: {Path.basename(p), Enum.map(literals, fn [_, c] -> c end)}

      assert offenders == [], "raw colours: #{inspect(offenders)}"
    end
  end

  describe "the token layers" do
    test "light is defined unconditionally" do
      css = read(@theme_css)

      # A palette defined only inside a media query leaves the page unstyled
      # for anyone whose system does not match it.
      assert css =~ ~r/:root\s*\{/
      assert css =~ "--bg:"
      assert css =~ "--text:"
    end

    test "an explicit choice overrides the system preference in both directions" do
      css = read(@theme_css)

      # Without the :not([data-theme="light"]) guard, a dark system setting
      # wins over a user who explicitly chose light, and the toggle only works
      # one way.
      #
      # Asserting the guard appears *somewhere* is not enough -- it appears
      # more than once, so removing it from the palette block still passes.
      # This checks the block that actually carries the dark values.
      [_, after_media] = String.split(css, "@media (prefers-color-scheme: dark) {\n", parts: 2)
      [selector | _] = String.split(after_media, "{", parts: 2)

      assert String.contains?(selector, ":not([data-theme=\"light\"])"),
             """
             The dark palette block is selected by `#{String.trim(selector)}`.

             Without the :not([data-theme="light"]) guard a dark system setting
             overrides an explicit light choice, so the toggle only works one way.
             """

      assert String.contains?(css, ":root[data-theme=\"dark\"]")
    end

    test "color-scheme is declared so form controls follow" do
      # Without it, native inputs and scrollbars stay light on a dark page.
      assert read(@theme_css) =~ "color-scheme:"
    end
  end

  describe "legibility" do
    test "text and links clear WCAG AA in both themes" do
      css = read(@theme_css)
      light = tokens(css, ":root {")
      dark = tokens(css, ":root[data-theme=\"dark\"] {")

      pairs = [
        {"text", "bg"},
        {"text", "surface-card"},
        {"text-muted", "bg"},
        {"link", "bg"},
        {"link", "surface-card"},
        {"pre-text", "pre-bg"},
        {"code-text", "code-bg"},
        {"text", "footer-bg"}
      ]

      for {name, palette} <- [{"light", light}, {"dark", dark}], {fg, bg} <- pairs do
        ratio = contrast(Map.fetch!(palette, fg), Map.fetch!(palette, bg))

        assert ratio >= 4.5,
               "#{name}: --#{fg} on --#{bg} is #{Float.round(ratio, 2)}:1, below AA"
      end
    end

    test "risk levels stay readable in both themes" do
      # These carry the meaning of the report. In dark mode the tags are light
      # pastels, so the label has to darken -- white on the dark-mode green was
      # 2.11:1 before this was checked.
      css = read(@theme_css)

      dark_selector = ":root[data-theme=\"dark\"] {"

      for {name, selector} <- [{"light", ":root {"}, {"dark", dark_selector}] do
        palette = tokens(css, selector)

        for {tag, ink} <- [
              {"tag-green", "tag-ink"},
              {"tag-orange", "tag-ink-warm"},
              {"tag-red", "tag-ink"}
            ] do
          ratio = contrast(Map.fetch!(palette, ink), Map.fetch!(palette, tag))

          assert ratio >= 4.5,
                 "#{name}: --#{tag} label is #{Float.round(ratio, 2)}:1, below AA"
        end
      end
    end
  end

  defp tokens(css, selector) do
    [_, rest] = String.split(css, selector, parts: 2)
    [block, _] = String.split(rest, "}", parts: 2)

    Regex.scan(~r/--([a-z0-9-]+):\s*(#[0-9a-fA-F]{3,6})\s*;/, block)
    |> Map.new(fn [_, name, value] -> {name, value} end)
  end

  defp contrast(a, b) do
    la = luminance(a)
    lb = luminance(b)
    {hi, lo} = {max(la, lb), min(la, lb)}
    (hi + 0.05) / (lo + 0.05)
  end

  defp luminance("#" <> hex) do
    hex = if String.length(hex) == 3, do: String.duplicate(hex, 2), else: hex

    [r, g, b] =
      for <<pair::binary-size(2) <- hex>> do
        v = String.to_integer(pair, 16) / 255
        if v <= 0.03928, do: v / 12.92, else: :math.pow((v + 0.055) / 1.055, 2.4)
      end

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end
end
