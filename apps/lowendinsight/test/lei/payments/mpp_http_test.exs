defmodule Lei.Payments.HttpTest do
  use ExUnit.Case, async: false

  import Mox
  import Plug.Test
  import Plug.Conn

  alias Lei.{ApiKeys, Credits, Wallets}
  alias Lei.Payments.{ChallengeStore, Http}
  alias Lei.Payments.Mpp.{Challenge, Credential, Receipt}
  alias Lei.Payments.Rails.Mpp

  setup :verify_on_exit!

  setup do
    # Every test here shares an IP, so without this the settle bucket is
    # exhausted partway through the file and the failures look like payment
    # bugs rather than what they are.
    Lei.RateLimiter.clear()

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    address = "0x" <> String.duplicate("a", 39) <> "1"
    {:ok, org} = Wallets.provision(address)

    %{org: org}
  end

  defp issue_challenge(org, credits \\ 15_000) do
    conn = Http.challenge(conn(:get, "/v1/analyze"), org.id, credits)
    [header] = get_resp_header(conn, "www-authenticate")
    {:ok, challenge} = Challenge.from_header(header)
    {conn, challenge}
  end

  defp credential_header(challenge, overrides \\ %{}) do
    echoed =
      %{
        "id" => challenge.id,
        "realm" => challenge.realm,
        "method" => challenge.method,
        "intent" => challenge.intent,
        "request" => Challenge.encode_json(challenge.request)
      }
      |> Map.merge(overrides)

    Credential.to_header(%Credential{
      challenge: echoed,
      payload: %{"spt" => "spt_test"},
      source: "acct_agent"
    })
  end

  defp with_credential(header) do
    conn(:get, "/v1/analyze") |> put_req_header("authorization", header)
  end

  defp intent(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "pi_http_1",
        "status" => "succeeded",
        "amount" => 1500,
        "amount_received" => 1500,
        "currency" => "usd"
      },
      overrides
    )
  end

  describe "the 402 challenge" do
    test "answers with the Payment scheme, not a bespoke body", %{org: org} do
      {conn, _} = issue_challenge(org)

      assert conn.status == 402
      assert [header] = get_resp_header(conn, "www-authenticate")
      assert String.starts_with?(header, "Payment ")
    end

    test "restates the price in the body for callers that do not speak the scheme", %{org: org} do
      {conn, _} = issue_challenge(org)
      body = Poison.decode!(conn.resp_body)

      assert body["error"] == "payment required"
      assert body["credits"] == 15_000
      assert body["amount"] == "1500"
      assert body["currency"] == "usd"
      assert is_binary(body["challenge_id"])
    end

    test "records the challenge against the org it was issued to", %{org: org} do
      # A credential proves a payment happened, not who it was for.
      {_conn, challenge} = issue_challenge(org)

      assert {:ok, _challenge, record} = ChallengeStore.fetch(challenge.id)
      assert record.org_id == org.id
      assert record.rail == "mpp"
      assert record.credits == 15_000
      assert is_nil(record.settled_at)
    end
  end

  describe "settling" do
    test "a paid retry credits the org and returns a receipt", %{org: org} do
      {_conn, challenge} = issue_challenge(org)
      expect(Lei.StripeMock, :create_payment_intent, fn _ -> {:ok, intent()} end)

      assert {:ok, conn, settlement} = Http.settle(with_credential(credential_header(challenge)))

      assert settlement.credits == 15_000
      assert Credits.balance(org.id) == 15_000

      assert [receipt_header] = get_resp_header(conn, "payment-receipt")
      assert {:ok, receipt} = Receipt.from_header(receipt_header)
      assert receipt.reference == "pi_http_1"
      assert receipt.method == "mpp"
    end

    test "marks the challenge settled", %{org: org} do
      {_conn, challenge} = issue_challenge(org)
      expect(Lei.StripeMock, :create_payment_intent, fn _ -> {:ok, intent()} end)

      {:ok, _conn, _} = Http.settle(with_credential(credential_header(challenge)))

      {:ok, _challenge, record} = ChallengeStore.fetch(challenge.id)
      refute is_nil(record.settled_at)
    end

    test "credits the org the challenge was issued to, not whoever presents it", %{org: org} do
      # The attack this prevents: intercept a credential, present it yourself.
      {:ok, other} =
        ApiKeys.find_or_create_org("Other #{System.unique_integer([:positive])}",
          status: "active"
        )

      {_conn, challenge} = issue_challenge(org)
      expect(Lei.StripeMock, :create_payment_intent, fn _ -> {:ok, intent()} end)

      {:ok, _conn, _} = Http.settle(with_credential(credential_header(challenge)))

      assert Credits.balance(org.id) == 15_000
      assert Credits.balance(other.id) == 0
    end

    test "the org cannot be supplied by the caller", %{org: org} do
      # org_id comes from the recorded challenge and nowhere else. Accepting it
      # as an option -- or from the request, or from the credential -- would
      # make the payer's money land in whichever balance the caller named.
      {:ok, other} =
        ApiKeys.find_or_create_org("Hijack #{System.unique_integer([:positive])}",
          status: "active"
        )

      {_conn, challenge} = issue_challenge(org)
      expect(Lei.StripeMock, :create_payment_intent, fn _ -> {:ok, intent()} end)

      {:ok, _conn, _} =
        Http.settle(with_credential(credential_header(challenge)), org_id: other.id)

      assert Credits.balance(org.id) == 15_000,
             "credits went somewhere other than the org the challenge was issued to"

      assert Credits.balance(other.id) == 0
    end

    test "a replayed credential does not credit twice", %{org: org} do
      # The agent paid once and retried. It is entitled to the resource either
      # way -- refusing the retry would take the money and withhold the work.
      {_conn, challenge} = issue_challenge(org)
      header = credential_header(challenge)

      expect(Lei.StripeMock, :create_payment_intent, 2, fn _ -> {:ok, intent()} end)

      assert {:ok, _, _} = Http.settle(with_credential(header))
      assert {:ok, _, _} = Http.settle(with_credential(header))

      assert Credits.balance(org.id) == 15_000
    end
  end

  describe "refusals" do
    test "no credential is not an error, it is the first half of the exchange" do
      assert :no_credential = Http.settle(conn(:get, "/v1/analyze"))
    end

    test "a credential for a challenge we never issued", %{org: org} do
      {_conn, real} = issue_challenge(org)
      forged = %{real | id: "never-issued-" <> real.id}

      assert {:error, :unknown_challenge} =
               Http.settle(with_credential(credential_header(forged)))
    end

    test "a credential echoing a different price", %{org: org} do
      {_conn, challenge} = issue_challenge(org)

      tampered =
        credential_header(challenge, %{
          "request" => Challenge.encode_json(%{"amount" => "1", "credits" => 15_000})
        })

      assert {:error, :challenge_mismatch} = Http.settle(with_credential(tampered))
      assert Credits.balance(org.id) == 0
    end

    test "a malformed credential" do
      assert {:error, :malformed_credential} =
               Http.settle(with_credential("Payment !!!not-base64!!!"))
    end

    test "an unpaid payment grants nothing", %{org: org} do
      {_conn, challenge} = issue_challenge(org)

      expect(Lei.StripeMock, :create_payment_intent, fn _ ->
        {:ok, intent(%{"status" => "processing"})}
      end)

      assert {:error, {:payment_not_settled, "processing"}} =
               Http.settle(with_credential(credential_header(challenge)))

      assert Credits.balance(org.id) == 0
    end
  end

  describe "rate limiting" do
    setup do
      original = Application.get_env(:lowendinsight, :rate_limits)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:lowendinsight, :rate_limits)
          value -> Application.put_env(:lowendinsight, :rate_limits, value)
        end
      end)

      Application.put_env(:lowendinsight, :rate_limits, %{
        free: 60,
        pro: 600,
        payment_challenge: 2,
        payment_settle: 2
      })

      :ok
    end

    test "asking the price repeatedly is bounded", %{org: org} do
      # Cheap, but each challenge writes a row, so an unbounded caller can fill
      # a table by doing nothing but asking what things cost.
      for _ <- 1..2, do: assert(Http.challenge(conn(:get, "/x"), org.id, 15_000).status == 402)

      limited = Http.challenge(conn(:get, "/x"), org.id, 15_000)

      assert limited.status == 429
      assert [_retry] = get_resp_header(limited, "retry-after")
    end

    test "presenting credentials repeatedly is bounded tighter", %{org: org} do
      # The expensive half: every attempt can reach Stripe, and this is what an
      # attacker would use to grind through stolen tokens.
      {_conn, challenge} = issue_challenge(org)
      header = credential_header(challenge)

      # The bucket allows two, so the third is the one refused.
      expect(Lei.StripeMock, :create_payment_intent, 2, fn _ -> {:ok, intent()} end)

      assert {:ok, _, _} = Http.settle(with_credential(header))
      assert {:ok, _, _} = Http.settle(with_credential(header))
      assert {:rate_limited, conn} = Http.settle(with_credential(header))

      assert conn.status == 429
    end

    test "a rate-limited challenge writes no row", %{org: org} do
      # The limit has to come before the work, or the thing being limited has
      # already happened.
      for _ <- 1..2, do: Http.challenge(conn(:get, "/x"), org.id, 15_000)

      before = Lei.Repo.aggregate(Lei.Payments.ChallengeStore.Record, :count, :id)
      Http.challenge(conn(:get, "/x"), org.id, 15_000)

      assert Lei.Repo.aggregate(Lei.Payments.ChallengeStore.Record, :count, :id) == before
    end

    test "a rate-limited settle never reaches Stripe", %{org: org} do
      # Mox fails the test if create_payment_intent is called, since none is
      # expected here.
      {_conn, challenge} = issue_challenge(org)
      header = credential_header(challenge)

      Lei.RateLimiter.check("payments:payment_settle:127.0.0.1", "payment_settle")
      Lei.RateLimiter.check("payments:payment_settle:127.0.0.1", "payment_settle")

      assert {:rate_limited, _conn} = Http.settle(with_credential(header))
    end
  end

  describe "housekeeping" do
    test "expired unanswered challenges are purged", %{org: org} do
      {_conn, challenge} = issue_challenge(org)

      assert ChallengeStore.purge_expired(DateTime.add(DateTime.utc_now(), 3600, :second)) >= 1
      assert {:error, :unknown_challenge} = ChallengeStore.fetch(challenge.id)
    end

    test "settled challenges survive the purge", %{org: org} do
      {_conn, challenge} = issue_challenge(org)
      expect(Lei.StripeMock, :create_payment_intent, fn _ -> {:ok, intent()} end)
      {:ok, _, _} = Http.settle(with_credential(credential_header(challenge)))

      ChallengeStore.purge_expired(DateTime.add(DateTime.utc_now(), 3600, :second))

      assert {:ok, _, _} = ChallengeStore.fetch(challenge.id)
    end
  end
end
