defmodule Lei.Payments.UpgradeUrlTest do
  @moduledoc """
  The upgrade link handed to a customer points at the canonical host.

  `Lei.Payments.Gate.limit_reached/2` hardcoded
  `https://lowendinsight.fly.dev/signup?tier=pro`. That is the hostname Fly
  assigns every app, not the one this service is named after, and it is the
  only customer-facing URL in the codebase that was still on it.

  Both hostnames resolve to the same machine today, which is why nothing broke
  and why nobody noticed: `lowendinsight.fly.dev` and `lowendinsight.dev`
  answer `/v1/health` with the same uptime. That stops being true the moment
  the app is renamed or moves off Fly, and the link a paying customer was sent
  is the last place to find out.

  Derived from `:lei_base_url` for the same reason the Stripe redirect URLs are
  (`Lei.Web.Router`): one setting decides where this service says it lives.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias Lei.{ApiKeys, Repo, UsageTracker}
  alias Lei.Payments.Gate

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp with_base_url(url, fun) do
    saved = Application.get_env(:lei_service, :lei_base_url)
    Application.put_env(:lei_service, :lei_base_url, url)

    try do
      fun.()
    after
      if is_nil(saved),
        do: Application.delete_env(:lei_service, :lei_base_url),
        else: Application.put_env(:lei_service, :lei_base_url, saved)
    end
  end

  # An org with no quota left, so admission refuses and the 402 carries the
  # upgrade link. Exercised through Gate.admit/2 rather than by calling the
  # private builder, because the link only reaches a customer down this path.
  defp exhausted_org_conn do
    {:ok, org} =
      ApiKeys.find_or_create_org("Upgrade #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    org = org |> Ecto.Changeset.change(free_tier_analyses_limit: 1) |> Repo.update!()
    {:ok, raw_key, api_key} = ApiKeys.create_api_key(org, "k", ["analyze"])
    _ = raw_key

    {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 1, 0)

    api_key = Repo.preload(api_key, :org)

    conn(:post, "/v1/analyze")
    |> Plug.Conn.assign(:current_api_key, api_key)
  end

  defp upgrade_url(conn) do
    {:halt, conn} = Gate.admit(conn, usage: {1, 0})
    assert conn.status == 402
    body = Poison.decode!(conn.resp_body)
    assert body["error"] == "free_tier_quota_exceeded"
    body["upgrade_url"]
  end

  test "the upgrade link uses the configured base url, not Fly's hostname" do
    with_base_url("https://lowendinsight.dev", fn ->
      url = upgrade_url(exhausted_org_conn())

      assert url == "https://lowendinsight.dev/signup?tier=pro"
      refute url =~ "fly.dev"
    end)
  end

  test "it follows the setting, so a rename is one change rather than a search" do
    with_base_url("https://example.test", fn ->
      assert upgrade_url(exhausted_org_conn()) == "https://example.test/signup?tier=pro"
    end)
  end
end
