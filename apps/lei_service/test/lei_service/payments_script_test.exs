defmodule LeiService.PaymentsScriptTest do
  @moduledoc """
  `scripts/payments.sh` is how an agent executes a payment runbook, so its
  contract is tested where CI runs it (#139):

    * stdout is one JSON object with `ok`; the exit code is 0 done and
      verified, 1 refused or not verified, 2 bad usage, 4 unreachable
    * a change is only reported done once it reads back through a different
      path than the one that made it
    * nothing an agent passes reaches the remote command unencoded
    * no secret in the environment ever appears in its output

  `flyctl` and `curl` are replaced on PATH by stubs that record each call and
  answer from files, so these run without production. The operations they
  stand in for are tested for real in `Lei.OperationsTest`.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../../../scripts/payments.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "payments-script-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    File.mkdir_p!(Path.join(dir, "responses"))

    # flyctl: record "<command> <base64 args>", answer with the next numbered
    # response for that command (or the unnumbered one), after the noise the
    # real flyctl prints.
    File.write!(Path.join(dir, "bin/flyctl"), """
    #!/usr/bin/env bash
    remote="${@: -1}"
    cmd=$(printf '%s' "$remote" | sed -n 's/.*Lei.Operations.cli(\\"\\([a-z_]*\\)\\", \\"\\([^\\"]*\\)\\").*/\\1/p')
    b64=$(printf '%s' "$remote" | sed -n 's/.*Lei.Operations.cli(\\"\\([a-z_]*\\)\\", \\"\\([^\\"]*\\)\\").*/\\2/p')
    printf '%s %s\\n' "$cmd" "$b64" >> "#{dir}/calls"
    [ -f "#{dir}/unreachable" ] && { echo "Error: no machines found"; exit 1; }
    n=$(grep -c "^$cmd " "#{dir}/calls")
    echo "Connecting to fdaa:0:33c6::2... complete"
    if [ -f "#{dir}/responses/$cmd.$n.json" ]; then cat "#{dir}/responses/$cmd.$n.json"; else cat "#{dir}/responses/$cmd.json"; fi
    """)

    File.write!(Path.join(dir, "bin/curl"), """
    #!/usr/bin/env bash
    cat "#{dir}/metrics" 2>/dev/null
    """)

    for stub <- ~w(flyctl curl), do: File.chmod!(Path.join(dir, "bin/#{stub}"), 0o755)

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp respond(dir, command, json),
    do: File.write!(Path.join(dir, "responses/#{command}.json"), json)

  defp respond(dir, command, n, json),
    do: File.write!(Path.join(dir, "responses/#{command}.#{n}.json"), json)

  defp metrics(dir, body), do: File.write!(Path.join(dir, "metrics"), body)

  defp run(dir, args, env \\ []) do
    {out, code} =
      System.cmd("bash", [@script | args],
        env:
          [
            {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")},
            {"PAYMENTS_VERIFY_ATTEMPTS", "2"},
            {"PAYMENTS_VERIFY_INTERVAL", "0"}
          ] ++ env,
        stderr_to_stdout: false
      )

    {out, code}
  end

  defp json(out) do
    lines = out |> String.split("\n", trim: true)
    assert length(lines) == 1, "stdout must be exactly one JSON line, got: #{inspect(out)}"
    Poison.decode!(hd(lines))
  end

  defp calls(dir) do
    case File.read(Path.join(dir, "calls")) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          [cmd, b64] = String.split(line, " ", parts: 2)
          {cmd, b64 |> Base.decode64!() |> Poison.decode!()}
        end)

      _ ->
        []
    end
  end

  test "the script exists and is executable" do
    assert File.stat!(@script).mode |> Bitwise.band(0o111) != 0
  end

  describe "switching a path off" do
    test "is done only once /metrics shows it off, and passes the reason through intact", %{
      dir: dir
    } do
      respond(dir, "switch", ~s({"ok":true,"path":"tempo","enabled":false,"changed":true}))
      metrics(dir, ~s(lei_payment_switch_enabled{path="tempo"} 0\n))

      reason = ~S|incident 7: "double" and 'single' quotes; $(not a command)|
      {out, code} = run(dir, ["switch-off", "tempo", "--reason", reason, "--actor", "agent"])

      assert code == 0
      assert %{"ok" => true, "verified" => true, "verified_by" => "/metrics"} = json(out)

      assert [
               {"switch",
                %{"path" => "tempo", "enabled" => false, "reason" => ^reason, "actor" => "agent"}}
             ] =
               calls(dir)
    end

    test "that production records but /metrics does not show is not done", %{dir: dir} do
      respond(dir, "switch", ~s({"ok":true,"path":"tempo","enabled":false,"changed":true}))
      metrics(dir, ~s(lei_payment_switch_enabled{path="tempo"} 1\n))

      {out, code} = run(dir, ["switch-off", "tempo", "--reason", "incident"])

      assert code == 1
      assert %{"ok" => false, "verified" => false, "error" => "not_verified"} = json(out)
    end

    test "refused by production exits 1 with production's reason", %{dir: dir} do
      respond(dir, "switch", ~s({"ok":false,"error":"reason_required"}))

      {out, code} = run(dir, ["switch-off", "tempo", "--reason", "x"])

      assert code == 1
      assert %{"ok" => false, "error" => "reason_required"} = json(out)
    end

    test "when production cannot be reached exits 4, distinctly from a refusal", %{dir: dir} do
      File.write!(Path.join(dir, "unreachable"), "")

      {out, code} = run(dir, ["switch-off", "tempo", "--reason", "incident"])

      assert code == 4
      assert %{"ok" => false, "error" => "unreachable"} = json(out)
    end
  end

  describe "bad input" do
    test "is refused before anything reaches production", %{dir: dir} do
      for args <- [
            ["switch-off", "paypal", "--reason", "x"],
            ["switch-off", "tempo"],
            ["switch-on", "tempo", "--reason", "   "],
            ["ledger", "pi_x';System.halt()"],
            ["release", "$(reboot)"],
            ["refund", "pi_ok", "--reason", "x", "--amount-cents", "-5"],
            ["refund", "pi_ok"],
            ["no-such-command"],
            []
          ] do
        {out, code} = run(dir, args)
        assert code == 2, "expected usage error for #{inspect(args)}, got #{code}: #{out}"
        assert %{"ok" => false, "error" => "usage"} = json(out)
      end

      assert calls(dir) == []
    end
  end

  describe "a refund" do
    test "is done once the ledger's refunded amount rises past what it was before", %{dir: dir} do
      respond(dir, "ledger", 1, ~s({"ok":true,"entries":[]}))

      respond(
        dir,
        "ledger",
        2,
        ~s({"ok":true,"entries":[{"reason":"reversal:mpp","metadata":{"amount_refunded_cents":500}}]})
      )

      respond(
        dir,
        "refund",
        ~s({"ok":true,"refund":"re_1","status":"succeeded","amount_cents":500})
      )

      {out, code} =
        run(dir, ["refund", "pi_ok", "--reason", "customer asked", "--amount-cents", "500"])

      assert code == 0
      assert %{"ok" => true, "verified" => true, "ledger_refunded_cents" => 500} = json(out)

      assert Enum.any?(
               calls(dir),
               &match?(
                 {"refund",
                  %{
                    "payment_intent" => "pi_ok",
                    "amount_cents" => 500,
                    "reason" => "customer asked"
                  }},
                 &1
               )
             )
    end

    test "is not done while the ledger shows only an earlier refund", %{dir: dir} do
      earlier =
        ~s({"ok":true,"entries":[{"reason":"reversal:mpp","metadata":{"amount_refunded_cents":500}}]})

      respond(dir, "ledger", earlier)

      respond(
        dir,
        "refund",
        ~s({"ok":true,"refund":"re_2","status":"succeeded","amount_cents":500})
      )

      {out, code} = run(dir, ["refund", "pi_ok", "--reason", "second", "--amount-cents", "500"])

      assert code == 1
      assert %{"ok" => false, "error" => "reversal_not_seen"} = json(out)
    end
  end

  describe "reading" do
    test "status passes production's JSON through", %{dir: dir} do
      respond(dir, "status", ~s({"ok":true,"switches":{"tempo":{"enabled":true}},"held":{}}))

      {out, code} = run(dir, ["status"])

      assert code == 0
      assert %{"ok" => true, "switches" => %{"tempo" => %{"enabled" => true}}} = json(out)
    end
  end

  test "never prints a secret from its environment", %{dir: dir} do
    respond(dir, "status", ~s({"ok":true}))
    File.write!(Path.join(dir, "unreachable"), "")

    secrets = [
      {"LEI_ADMIN_TOKEN", "admin-token-should-never-appear"},
      {"STRIPE_SECRET_KEY", "sk_live_should_never_appear"},
      {"FLY_API_TOKEN", "fly-token-should-never-appear"}
    ]

    for args <- [["status"], ["switch-off", "tempo", "--reason", "x"], ["ledger", "bad id!"]] do
      {out, _} =
        System.cmd("bash", [@script | args],
          env: [{"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")}] ++ secrets,
          stderr_to_stdout: true
        )

      for {_, value} <- secrets, do: refute(out =~ value)
    end
  end
end
