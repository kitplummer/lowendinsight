defmodule Lei.WebhookMonitoringTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import Mox

  alias Lei.{Metrics, WebhookStats}

  @secret "whsec_test_secret_for_monitoring"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    WebhookStats.reset()

    # These tests are about signature verification itself, so the mock delegates
    # to the real implementation rather than asserting it was called.
    stub(Lei.StripeMock, :construct_webhook_event, fn payload, signature, secret ->
      Lei.Stripe.construct_webhook_event(payload, signature, secret)
    end)

    original = Application.get_env(:lowendinsight, :stripe_webhook_secret)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:lowendinsight, :stripe_webhook_secret)
        value -> Application.put_env(:lowendinsight, :stripe_webhook_secret, value)
      end

      WebhookStats.reset()
    end)

    :ok
  end

  defp post_webhook(body, signature) do
    conn = conn(:post, "/webhooks/stripe", body)

    conn
    |> put_req_header("content-type", "application/json")
    |> then(fn c ->
      if signature, do: put_req_header(c, "stripe-signature", signature), else: c
    end)
    |> put_private(:raw_body, body)
    |> Lei.Web.Router.call(Lei.Web.Router.init([]))
  end

  defp sign(body, secret) do
    timestamp = System.system_time(:second)

    signature =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end

  describe "outcomes are distinguished" do
    test "a request with no stripe-signature is not counted as a secret failure" do
      # A public URL attracts scanners. Counting their POSTs as signature
      # failures would make the alert useless within a day.
      conn = post_webhook(~s({"type":"noise"}), nil)

      assert conn.status == 400
      assert WebhookStats.count(:unsigned) == 1
      assert WebhookStats.count(:invalid) == 0
      assert WebhookStats.count(:unconfigured) == 0
    end

    test "a signed request with no secret configured counts as unconfigured" do
      Application.delete_env(:lowendinsight, :stripe_webhook_secret)
      body = ~s({"type":"checkout.session.completed"})

      conn = post_webhook(body, sign(body, @secret))

      assert conn.status == 400
      assert WebhookStats.count(:unconfigured) == 1
      assert WebhookStats.count(:invalid) == 0
    end

    test "a signed request with the wrong secret counts as invalid" do
      # The rotation failure: endpoint rolled, Fly not updated.
      Application.put_env(:lowendinsight, :stripe_webhook_secret, @secret)
      body = ~s({"type":"checkout.session.completed"})

      conn = post_webhook(body, sign(body, "whsec_a_different_secret"))

      assert conn.status == 400
      assert WebhookStats.count(:invalid) == 1
      assert WebhookStats.count(:unconfigured) == 0
    end

    test "a correctly signed request counts as ok" do
      Application.put_env(:lowendinsight, :stripe_webhook_secret, @secret)
      body = ~s({"type":"some.unhandled.event","data":{"object":{}}})

      conn = post_webhook(body, sign(body, @secret))

      assert conn.status == 200
      assert WebhookStats.count(:ok) == 1
      assert WebhookStats.count(:invalid) == 0
    end

    test "an empty-string secret is treated as unconfigured, not as a mismatch" do
      # An unset Fly secret arrives as "" rather than nil in some paths. Both
      # mean the same thing and must not be reported as a rotation problem.
      Application.put_env(:lowendinsight, :stripe_webhook_secret, "")
      body = ~s({"type":"checkout.session.completed"})

      conn = post_webhook(body, sign(body, @secret))

      assert conn.status == 400
      assert WebhookStats.count(:unconfigured) == 1
      assert WebhookStats.count(:invalid) == 0
    end
  end

  describe "metrics exposure" do
    test "counters appear on the metrics endpoint" do
      Application.put_env(:lowendinsight, :stripe_webhook_secret, @secret)
      body = ~s({"type":"x","data":{"object":{}}})

      post_webhook(body, sign(body, "whsec_wrong"))
      post_webhook(body, sign(body, @secret))

      output = Metrics.collect()

      assert output =~ "lei_stripe_webhook_total"
      assert output =~ ~s(lei_stripe_webhook_total{result="invalid"} 1)
      assert output =~ ~s(lei_stripe_webhook_total{result="ok"} 1)
    end

    test "every outcome is reported even at zero" do
      # Prometheus cannot alert on a series that does not exist. A counter that
      # only appears after the first failure is a counter that alerts late.
      output = Metrics.collect()

      for outcome <- WebhookStats.outcomes() do
        assert output =~ ~s(lei_stripe_webhook_total{result="#{outcome}"} 0)
      end
    end
  end

  describe "counter behaviour" do
    test "counts accumulate rather than overwrite" do
      body = ~s({"type":"noise"})

      for _ <- 1..3, do: post_webhook(body, nil)

      assert WebhookStats.count(:unsigned) == 3
    end

    test "the table is created on demand, not only at boot" do
      # Plug init/1 runs at compile time in a release, so boot-time setup is
      # absent at runtime. That took down /v1/analyze once (#91).
      :ets.delete(:lei_webhook_stats)

      assert WebhookStats.count(:ok) == 0
      assert :ok = WebhookStats.record(:ok)
      assert WebhookStats.count(:ok) == 1
    end
  end
end
