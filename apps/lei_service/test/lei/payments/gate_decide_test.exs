defmodule Lei.Payments.GateDecideTest do
  @moduledoc """
  `Gate.decide/2` reaches admission's decision without answering anyone.

  MCP needs the decision -- the same org, the same charge, the same refusal --
  without the HTTP answer: a refusal reaches an MCP client as a tool result,
  not as a 402 with payment challenges. So deciding must not send, and an
  admitted request must have been charged exactly as `admit/2` charges it.
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

  defp key_conn(org) do
    {:ok, _raw, api_key} = ApiKeys.create_api_key(org, "k", ["analyze"])

    conn(:post, "/mcp")
    |> Plug.Conn.assign(:current_api_key, Repo.preload(api_key, :org))
  end

  defp org(attrs) do
    {:ok, org} =
      ApiKeys.find_or_create_org("Decide #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    org |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  test "an anonymous caller is refused with what to pay, and nothing is sent" do
    conn = conn(:post, "/mcp")

    assert {:payment_required, nil, credits} =
             Gate.decide(conn, required_credits: 50, usage: {0, 1})

    assert credits >= 50
    assert conn.state == :unset
    refute conn.halted
  end

  test "an operator token is admitted unbilled" do
    conn = conn(:post, "/mcp") |> Plug.Conn.assign(:auth_method, :jwt)

    assert {:ok, {nil, nil, nil}} = Gate.decide(conn, usage: {0, 1})
  end

  test "an org with quota is admitted and charged, as admit/2 would" do
    org = org(free_tier_analyses_limit: 10)
    conn = key_conn(org)

    assert {:ok, {org_id, _key_id, "free"}} = Gate.decide(conn, usage: {1, 2})
    assert org_id == org.id
    assert conn.state == :unset
    assert %{cache_hits: 1, cache_misses: 2} = UsageTracker.get_current_usage(org.id)
  end

  test "an org over its free allowance is refused, and nothing is sent" do
    org = org(free_tier_analyses_limit: 1)
    conn = key_conn(org)
    {:ok, _} = UsageTracker.record_usage(org.id, conn.assigns.current_api_key.id, 1, 0)

    assert {:quota_exceeded, %{}} = Gate.decide(conn, usage: {1, 0})
    assert conn.state == :unset
  end

  test "refuse/2 sends what admit/2 sends for the same refusal" do
    org = org(free_tier_analyses_limit: 1)
    conn = key_conn(org)
    {:ok, _} = UsageTracker.record_usage(org.id, conn.assigns.current_api_key.id, 1, 0)

    refusal = Gate.decide(conn, usage: {1, 0})
    {:halt, admitted} = Gate.admit(conn, usage: {1, 0})
    refused = Gate.refuse(conn, refusal)

    assert {refused.status, Poison.decode!(refused.resp_body)} ==
             {admitted.status, Poison.decode!(admitted.resp_body)}

    assert refused.halted
  end
end
