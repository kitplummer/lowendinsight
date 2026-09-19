defmodule LeiService.VerifyWebhookScriptTest do
  @moduledoc """
  `scripts/verify-webhook-secret.sh` answers a question nothing else can.

  A wrong Stripe signing secret fails exactly like an unset one from outside:
  every delivery 400s, subscriptions quietly stop activating, and nothing else
  changes (`BILLING_SETUP.md` section 3). Only a real delivery distinguishes
  them, so this script is the only thing that can tell the difference — which
  makes it worth knowing that it reports the difference correctly.

  Its first version did not. It chose an event the handler ignores, so nothing
  would act on it, without noticing that the endpoint subscribes to exactly
  the seven types the handler acts on: "safe to resend" and "will actually be
  delivered" were disjoint sets. Stripe accepted the resend, delivered
  nothing, and the script reported NOTHING ARRIVED against a healthy system.

  `stripe` and `curl` are replaced on PATH by stubs, so each outcome is
  exercised without touching Stripe or production. The counters the script
  reads are scripted to change, or not, between the calls either side of the
  redelivery.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../../../scripts/verify-webhook-secret.sh", __DIR__)

  @endpoint "we_test123"
  @host "lowendinsight.dev"

  setup do
    dir = Path.join(System.tmp_dir!(), "webhook-script-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # Counters are read three times: before, then repeatedly after. "after" is
  # whatever the scenario says the second read onwards should show.
  defp stub_curl(dir, before_metrics, after_metrics) do
    File.write!(Path.join(dir, "bin/curl"), """
    #!/usr/bin/env bash
    for arg in "$@"; do
      case "$arg" in
        *"/v1/health") echo '{"uptime_seconds": 1000}'; exit 0 ;;
      esac
    done

    n=$(cat "#{dir}/metrics_calls" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "#{dir}/metrics_calls"

    if [ "$n" -le 1 ]; then
      cat "#{dir}/before_metrics"
    else
      cat "#{dir}/after_metrics"
    fi
    """)

    File.chmod!(Path.join(dir, "bin/curl"), 0o755)
    File.write!(Path.join(dir, "before_metrics"), before_metrics)
    File.write!(Path.join(dir, "after_metrics"), after_metrics)
  end

  defp metrics(opts) do
    """
    lei_stripe_webhook_total{result="ok"} #{Keyword.get(opts, :ok, 0)}
    lei_stripe_webhook_total{result="unconfigured"} #{Keyword.get(opts, :unconfigured, 0)}
    lei_stripe_webhook_total{result="invalid"} #{Keyword.get(opts, :invalid, 0)}
    lei_stripe_webhook_total{result="stale"} #{Keyword.get(opts, :stale, 0)}
    lei_stripe_webhook_total{result="unsigned"} 0
    """
  end

  defp stub_stripe(dir, opts) do
    url = Keyword.get(opts, :url, "https://#{@host}/webhooks/stripe")
    status = Keyword.get(opts, :status, "enabled")
    events = Keyword.get(opts, :events, ["payment_intent.created"])

    File.write!(Path.join(dir, "bin/stripe"), """
    #!/usr/bin/env bash
    echo "$@" >> "#{dir}/stripe_calls"

    case "$1 $2" in
      "get /v1/webhook_endpoints")
        echo '{"data":[{"id":"#{@endpoint}","url":"#{url}","status":"#{status}","enabled_events":["checkout.session.completed"]}]}'
        ;;
      "get /v1/webhook_endpoints/#{@endpoint}")
        echo '{"id":"#{@endpoint}","enabled_events":["checkout.session.completed"]}'
        ;;
      "get /v1/events")
        echo '{"data":[#{events |> Enum.map(&~s({"id":"evt_1","type":"#{&1}"})) |> Enum.join(",")}]}'
        ;;
      *) echo '{}' ;;
    esac
    exit 0
    """)

    File.chmod!(Path.join(dir, "bin/stripe"), 0o755)
  end

  defp run(dir) do
    System.cmd("bash", [@script, "https://#{@host}"],
      cd: dir,
      env: [{"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")}],
      stderr_to_stdout: true
    )
  end

  defp stripe_calls(dir) do
    case File.read(Path.join(dir, "stripe_calls")) do
      {:ok, s} -> String.split(s, "\n", trim: true)
      _ -> []
    end
  end

  describe "the secret matches" do
    test "reports VERIFIED and exits 0", %{dir: dir} do
      stub_stripe(dir, [])
      stub_curl(dir, metrics(ok: 0), metrics(ok: 1))

      {out, code} = run(dir)

      assert out =~ "VERIFIED"
      assert code == 0
    end

    test "puts the subscription back", %{dir: dir} do
      stub_stripe(dir, [])
      stub_curl(dir, metrics(ok: 0), metrics(ok: 1))

      run(dir)

      posts = Enum.filter(stripe_calls(dir), &String.starts_with?(&1, "post"))

      assert length(posts) >= 2,
             "expected a subscribe and a restore, got: #{inspect(posts)}"

      assert List.last(posts) =~ "checkout.session.completed",
             "the last write did not restore the original events"
    end
  end

  describe "the secret is wrong" do
    # The failure section 3 warns arrives a day late, because Stripe keeps a
    # rolled secret valid for 24 hours.
    test "is not reported as verified", %{dir: dir} do
      stub_stripe(dir, [])
      stub_curl(dir, metrics(ok: 0), metrics(invalid: 1))

      {out, code} = run(dir)

      assert out =~ "WRONG SECRET"
      refute out =~ "VERIFIED:"
      assert code == 1
    end
  end

  describe "the secret is not set" do
    test "is distinguished from a wrong one", %{dir: dir} do
      stub_stripe(dir, [])
      stub_curl(dir, metrics(ok: 0), metrics(unconfigured: 1))

      {out, code} = run(dir)

      assert out =~ "NOT SET"
      assert code == 1
    end
  end

  describe "the delivery never arrives" do
    # The state the first version of this script produced against a perfectly
    # healthy system. It must not read as success, and it must not read as a
    # secret problem either.
    test "says so, and says it is not the secret", %{dir: dir} do
      stub_stripe(dir, [])
      stub_curl(dir, metrics(ok: 0), metrics(ok: 0))

      {out, code} = run(dir)

      assert out =~ "NOTHING ARRIVED"
      assert out =~ "reachability"
      refute out =~ "VERIFIED"
      assert code == 1
    end
  end

  describe "it refuses when it cannot do its job" do
    test "no endpoint registered for the host", %{dir: dir} do
      stub_stripe(dir, url: "https://example.invalid/webhooks/stripe")
      stub_curl(dir, metrics(ok: 0), metrics(ok: 1))

      {out, code} = run(dir)

      assert out =~ "no webhook endpoint registered"
      refute out =~ "VERIFIED"
      assert code == 1
    end

    test "the endpoint is disabled", %{dir: dir} do
      stub_stripe(dir, status: "disabled")
      stub_curl(dir, metrics(ok: 0), metrics(ok: 1))

      {out, code} = run(dir)

      assert out =~ "disabled"
      refute out =~ "VERIFIED"
      assert code == 1
    end

    test "every available event is one the handler acts on", %{dir: dir} do
      # Redelivering one of these would activate an org or move credits, so
      # there is nothing safe to send and the script must say so rather than
      # pick one.
      stub_stripe(dir, events: ["checkout.session.completed", "charge.refunded"])
      stub_curl(dir, metrics(ok: 0), metrics(ok: 1))

      {out, code} = run(dir)

      assert out =~ "No event of an unhandled type"
      refute out =~ "VERIFIED"
      assert code == 1
    end

    test "metrics publish no webhook counters", %{dir: dir} do
      stub_stripe(dir, [])
      stub_curl(dir, "", "")

      {out, code} = run(dir)

      assert out =~ "no webhook counters"
      refute out =~ "VERIFIED"
      assert code == 1
    end
  end
end
