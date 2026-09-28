defmodule LeiService.BetaWebContentTest do
  @moduledoc """
  What the web pages say while analysis is free.

  Beta was shipped and labelled in `/llms.txt` and `/terms` only. The signup
  form still offered Pro at $29/mo, the analyze page still said the service is
  "paid per use" and printed a price table, and the homepage said nothing at
  all. A page that quotes a price the ledger does not take is this codebase's
  usual failure in prose, and `AgentGuide` exists because of it -- but the human
  pages are rendered from the same facts and were not checked.

  Every assertion here is against a rendered response, in both modes, because
  the labelling has to appear when beta is on and disappear when it is not. A
  banner hardcoded into a template would pass a grep and would still be there
  next year.
  """
  use ExUnit.Case, async: false

  alias Lei.Repo

  @opts LeiService.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    saved = Application.get_env(:lei_service, :billing_mode)
    on_exit(fn -> Application.put_env(:lei_service, :billing_mode, saved) end)
    :ok
  end

  defp beta!, do: Application.put_env(:lei_service, :billing_mode, :beta)
  defp charging!, do: Application.put_env(:lei_service, :billing_mode, :charge)

  defp get(path) do
    :get |> Plug.Test.conn(path) |> LeiService.Endpoint.call(@opts)
  end

  describe "the banner" do
    test "every page carries it during beta" do
      beta!()

      # "/" renders analyze.html -- the homepage and the pricing page are one page.
      for path <- ["/", "/signup", "/login"] do
        conn = get(path)

        assert conn.status in [200, 302],
               "#{path} did not render (status #{conn.status})"

        if conn.status == 200 do
          assert conn.resp_body =~ "beta",
                 "#{path} does not mention beta anywhere"
        end
      end
    end

    test "it is gone when beta is over" do
      # The point of driving it from the mode: nobody has to remember to remove
      # a banner, and a page cannot advertise a beta that ended.
      charging!()
      body = get("/").resp_body

      refute body =~ "Analysis is free during beta",
             "the beta banner survives the end of beta"
    end
  end

  describe "signup" do
    test "Pro is not on sale during beta" do
      # During beta a Pro org gets the same allowance as a free one (ADR-007),
      # so $29/mo would buy a rate limit nobody can exhaust at 200 analyses a
      # month.
      beta!()
      body = get("/signup").resp_body

      refute body =~ "$29/mo",
             "Pro is still offered at $29/mo while it buys nothing extra"

      refute body =~ ~s(value="pro"),
             "the Pro radio is still selectable during beta"

      assert body =~ "beta", "signup does not say it is a beta"
    end

    test "posting tier=pro is refused during beta, not just hidden" do
      # Hiding the radio is a form change. The path still accepted tier=pro, so
      # anything posting directly could subscribe and receive the same allowance
      # as a free account. Harmless while Stripe is in test mode, and not
      # harmless the day it goes live with beta still on.
      conn =
        :post
        |> Plug.Test.conn("/signup", "name=Beta+Probe&tier=pro")
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")

      beta!()
      conn = LeiService.Endpoint.call(conn, @opts)

      refute conn.status in [302, 303],
             "tier=pro was accepted during beta and redirected to checkout"

      assert conn.resp_body =~ "beta",
             "the refusal does not explain that paid plans are unavailable during beta"
    end

    test "Pro comes back when charging resumes" do
      charging!()
      body = get("/signup").resp_body

      assert body =~ "$29/mo", "Pro disappeared permanently"
      assert body =~ ~s(value="pro")
    end
  end

  describe "the analyze page" do
    test "it does not describe per-use charging while there is none" do
      beta!()
      body = get("/").resp_body

      assert body =~ "free",
             "the page describing how to pay says nothing about analysis being free"

      # The prices stay visible -- they are what will apply -- but must not read
      # as what happens now.
      assert body =~ "when beta ends" or body =~ "after beta",
             "the price table is presented as current"
    end

    test "the prices are still published" do
      beta!()
      body = get("/").resp_body

      assert body =~ "credits",
             "the rates vanished, so they will appear from nowhere when beta ends"
    end
  end
end
