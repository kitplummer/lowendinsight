defmodule LowendinsightGet.FaviconTest do
  use ExUnit.Case, async: false

  import Plug.Test

  @opts LowendinsightGet.Endpoint.init([])

  @templates ~w(analyze.html.eex analysis.html.eex language.html.eex index.html.eex)

  @icons [
    {"/favicon.ico", "image/vnd.microsoft.icon"},
    {"/images/favicon-32.png", "image/png"},
    {"/images/favicon-16.png", "image/png"},
    {"/images/apple-touch-icon.png", "image/png"}
  ]

  describe "the files are served" do
    test "/favicon.ico is served from the root" do
      # Browsers request this whether or not a link tag points at it, so the
      # root path has to work on its own. Plug.Static is mounted at /images,
      # /js and /css, none of which cover it.
      conn = LowendinsightGet.Endpoint.call(conn(:get, "/favicon.ico"), @opts)

      assert conn.status == 200
      assert byte_size(conn.resp_body) > 0
    end

    test "every icon referenced by the templates is served" do
      for {path, _type} <- @icons do
        conn = LowendinsightGet.Endpoint.call(conn(:get, path), @opts)

        assert conn.status == 200, "#{path} returned #{conn.status}"
      end
    end

    test "the root mount does not expose the rest of priv/static" do
      # `only: ~w(favicon.ico)` is doing real work here. Without it, mounting
      # priv/static/images at / would serve every image from the root as well.
      conn = LowendinsightGet.Endpoint.call(conn(:get, "/lei_bus_128.png"), @opts)

      refute conn.status == 200
    end
  end

  describe "the pages reference them" do
    test "all four templates carry the icon links" do
      # The attribution change was a reminder that this project has four page
      # templates and it is easy to update one and believe the job done. A
      # favicon on the landing page and missing from the report page is the
      # same bug in a smaller costume.
      for template <- @templates do
        source = File.read!(Path.join(File.cwd!(), "priv/templates/#{template}"))

        assert source =~ "rel=\"icon\"", "#{template} has no icon link"

        assert source =~ "apple-touch-icon",
               "#{template} has no apple-touch-icon link"
      end
    end

    test "the landing page's links resolve to files that exist" do
      body =
        conn(:get, "/")
        |> LowendinsightGet.Endpoint.call(@opts)
        |> Map.fetch!(:resp_body)

      referenced =
        Regex.scan(~r/<link[^>]+href="([^"]+)"/, body)
        |> Enum.map(fn [_, href] -> href end)
        |> Enum.filter(&String.contains?(&1, "favicon"))

      assert referenced != [], "the rendered page references no favicon at all"

      for href <- referenced do
        conn = LowendinsightGet.Endpoint.call(conn(:get, href), @opts)
        assert conn.status == 200, "#{href} is linked but returns #{conn.status}"
      end
    end
  end

  describe "the images themselves" do
    test "the icons are the sizes they claim to be" do
      # A link that says sizes="32x32" pointing at a 16px file is worse than no
      # link: the browser trusts the declaration.
      for {path, size} <- [{"images/favicon-16.png", 16}, {"images/favicon-32.png", 32}] do
        full = Path.join([File.cwd!(), "priv/static", path])
        assert {width, height} = png_dimensions(File.read!(full))
        assert {width, height} == {size, size}, "#{path} is #{width}x#{height}, not #{size}"
      end
    end

    test "the apple touch icon is opaque" do
      # iOS composites transparency onto black, which would put the bus in a
      # black square rather than on the page's own background.
      full = Path.join([File.cwd!(), "priv/static/images/apple-touch-icon.png"])
      # IHDR: 8 byte signature, 4 length, 4 "IHDR", 4 width, 4 height, 1 bit
      # depth, then colour type at offset 25.
      <<_::binary-size(25), color_type, _::binary>> = File.read!(full)

      # PNG colour type 2 is truecolour without alpha; 6 would carry it.
      assert color_type == 2, "apple-touch-icon has an alpha channel (colour type #{color_type})"
    end
  end

  # PNG width and height live at a fixed offset in the IHDR chunk.
  defp png_dimensions(<<_::binary-size(16), w::32, h::32, _::binary>>), do: {w, h}
end
