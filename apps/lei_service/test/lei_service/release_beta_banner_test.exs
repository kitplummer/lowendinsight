defmodule LeiService.ReleaseBetaBannerTest do
  @moduledoc """
  Every web page says when the running release is a beta.

  The billing banner (`BetaWebContentTest`) follows `Lei.Billing.mode/0`, which
  is about whether analysis is charged. Whether the software is a pre-release
  is a different fact with a different source: the version. 0.16.0-beta.1 went
  out to Hex, GHCR, the API and the MCP client labelled as a beta while the web
  UI -- the one interface a person sees first -- said nothing about it outside
  the free-analysis notice, and showed `v0.16.0-beta.1` in grey in the footer.

  Driven from the version, so the banner leaves with the pre-release suffix and
  nobody has to remember to remove it at 1.0.
  """
  use ExUnit.Case, async: false

  alias Lei.Web.Release

  @opts LeiService.Endpoint.init([])
  @templates Path.expand("../../priv", __DIR__)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    saved = Application.get_env(:lei_service, :billing_mode)
    on_exit(fn -> Application.put_env(:lei_service, :billing_mode, saved) end)
    :ok
  end

  defp get(path), do: :get |> Plug.Test.conn(path) |> LeiService.Endpoint.call(@opts)

  defp running, do: Application.spec(:lei_service, :vsn) |> to_string()

  describe "the banner itself" do
    test "a pre-release names itself a beta, with its version" do
      {:safe, html} = Release.banner("0.16.0-beta.1")
      html = IO.iodata_to_binary(html)

      assert html =~ ~r/\bbeta\b/i
      assert html =~ "0.16.0-beta.1"
    end

    test "a release has no banner" do
      assert Release.banner("1.0.0") == {:safe, ""}
    end

    test "the version is escaped" do
      {:safe, html} = Release.banner("1.0.0-<b>")
      refute IO.iodata_to_binary(html) =~ "<b>"
    end
  end

  describe "on the pages" do
    test "every reachable page carries it, whatever the billing mode" do
      if String.contains?(running(), "-") do
        for mode <- [:beta, :charge],
            path <- ["/", "/terms", "/signup", "/login", "/recover"] do
          Application.put_env(:lei_service, :billing_mode, mode)
          conn = get(path)

          assert conn.status == 200, "#{path} did not render (status #{conn.status})"

          assert conn.resp_body =~ ~s(id="release-beta"),
                 "#{path} (billing #{mode}) does not say #{running()} is a beta"

          assert conn.resp_body =~ running()
        end
      end
    end

    test "every page template renders it" do
      # Pages that need a cached report, an admin token or the network to reach
      # are covered here: each one renders the banner as the first thing in its
      # body.
      templates =
        Path.wildcard(Path.join(@templates, "**/*.html.eex"))
        |> Enum.filter(&(File.read!(&1) =~ "<body"))

      assert length(templates) >= 7, "found #{length(templates)} page templates"

      missing =
        for path <- templates,
            not (File.read!(path) =~ ~r/<body[^>]*>\s*<%= Lei\.Web\.Release\.banner\(\) %>/),
            do: Path.relative_to(path, @templates)

      assert missing == [], "these pages do not show the release banner: #{inspect(missing)}"
    end
  end
end
