defmodule LeiService.RequestLoggerPrivacyTest do
  @moduledoc """
  What was analysed is not recorded against a wallet that paid (#149).

  Decided 2026-09-14: a consumer does not register to get analysis, and for
  wallet orgs we keep money and counts, never which repositories. The request
  log is the one record that put the two side by side -- repo URLs next to the
  org and key, on the admin dashboard.
  """
  use ExUnit.Case, async: false

  alias LeiService.RequestLogger

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  defp unique_url, do: "https://github.com/example/privacy-#{System.unique_integer([:positive])}"

  defp logged(url) do
    # log_request/5 is a cast; the call below is processed after it.
    :sys.get_state(RequestLogger)
    Enum.filter(RequestLogger.get_all(), &(url in (&1.repo_urls || [])))
  end

  defp entry_for(org_id) do
    :sys.get_state(RequestLogger)
    Enum.find(RequestLogger.get_all(), &(&1.org_id == org_id))
  end

  test "a wallet org's request is counted, without what it analysed" do
    {:ok, org} = Lei.Wallets.provision("0x" <> String.duplicate("d", 40))
    url = unique_url()

    RequestLogger.log_request("/v1/analyze", org, 7, [url], :hit)

    assert logged(url) == []
    entry = entry_for(org.id)
    assert entry.cache_status == :hit
    assert entry.key_id == 7
    assert entry.repo_urls == []
    assert entry.repo_urls_withheld
  end

  test "a signed-up org's request keeps its URLs" do
    {:ok, org} =
      Lei.ApiKeys.find_or_create_org("Privacy Human #{System.unique_integer([:positive])}",
        status: "active"
      )

    url = unique_url()
    RequestLogger.log_request("/v1/analyze", org, 8, [url], :miss)

    assert [%{org_id: org_id, repo_urls_withheld: false}] = logged(url)
    assert org_id == org.id
  end

  test "the admin dashboard renders a withheld request as withheld, not as missing" do
    # The template renders at request time, so a mistake in it only shows when
    # someone opens /admin.
    previous = System.get_env("LEI_ADMIN_TOKEN")
    System.put_env("LEI_ADMIN_TOKEN", "privacy-test-token")

    on_exit(fn ->
      if previous,
        do: System.put_env("LEI_ADMIN_TOKEN", previous),
        else: System.delete_env("LEI_ADMIN_TOKEN")
    end)

    {:ok, org} = Lei.Wallets.provision("0x" <> String.duplicate("e", 40))
    url = unique_url()
    RequestLogger.log_request("/v1/analyze", org, 9, [url], :hit)
    :sys.get_state(RequestLogger)

    conn =
      Plug.Test.conn(:get, "/admin")
      |> Plug.Conn.put_req_header("authorization", "Bearer privacy-test-token")
      |> LeiService.Endpoint.call(LeiService.Endpoint.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ "withheld"
    refute conn.resp_body =~ url
  end

  test "an operator request with no org keeps its URLs" do
    url = unique_url()
    RequestLogger.log_request("/v1/analyze", nil, nil, [url], :miss)

    assert [%{org_id: nil}] = logged(url)
  end
end
