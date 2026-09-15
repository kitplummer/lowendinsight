defmodule Lei.Stripe.ObjectCheck do
  @moduledoc """
  Confirms, after boot, that the configured price IDs exist in the key's mode.

  Price IDs carry no mode marker, but Stripe will only return a price to a key
  from the same mode. So retrieving each price with the configured key *is* the
  mode check: a sandbox price under a live key comes back "No such price".

  ## Why after boot

  Doing this at boot would make Stripe's availability a condition of ours. The
  result feeds `/readyz` as an optional check instead, so a mismatch reads as
  `"degraded"` -- still serving, and loud in monitoring, which fails on
  degraded.

  ## Results

    * `"ok"` -- every configured price retrieved and active, and the key may
      read Checkout Sessions
    * `"mismatch"` -- a price does not exist for this key: the half-flip
    * `"inactive"` -- a price exists but is archived, so Checkout would refuse it
    * `"unauthorized"` -- the key itself was rejected. Rolled keys expire; this
      is how an expired one shows up before a customer finds it
    * `"unreachable"` -- Stripe could not be asked. Retried after a minute
    * `"unconfigured"` -- production with no key or no price IDs
    * `"pending"` -- the first check has not finished
    * `"malformed"` -- present but not a key. `Lei.Stripe.Mode.validate!/1`
      stops boot before this can be seen; it is here so this module never
      reports "ok" for a key it did not understand

  Outside production, no key at all is `"ok"`: billing is off on purpose there,
  and there is nothing configured to be wrong.
  """

  use GenServer
  require Logger

  @recheck_ms :timer.hours(1)
  @retry_ms :timer.minutes(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The latest result, for `Lei.Health`. Never raises; a checker that is not
  running is reported rather than crashing the probe.
  """
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status, 1_000)
  catch
    :exit, _ -> "not_running"
  end

  @doc """
  Whether Stripe has confirmed, with the configured key, that `address` is one of
  our deposit addresses. False whenever that is not positively known -- not yet
  checked, checker not running, Stripe unreachable -- because the cost of a
  wrong "yes" is an agent's money sent where Stripe will not credit it.
  """
  def deposit_address_confirmed?(address, server \\ __MODULE__) when is_binary(address) do
    GenServer.call(server, {:deposit_confirmed?, String.downcase(address)}, 1_000)
  catch
    :exit, _ -> false
  end

  @doc """
  Whether a configured Tempo deposit address belongs to the key's account.

  Deposit addresses carry no mode, like prices, and the same trick applies:
  list the account's addresses with the configured key. A sandbox address is
  absent from a live account's list.
  """
  def check_deposit_address(key, address, deploy_env, stripe_module) do
    case {Lei.Stripe.Mode.of(key), address} do
      {_, nil} ->
        # Stablecoin is optional. No address means no tempo challenges, which
        # the rail already reports; it is not a Stripe misconfiguration.
        "ok"

      {:malformed, _} ->
        "malformed"

      {:unconfigured, _} ->
        if Lei.Stripe.Mode.production?(deploy_env), do: "unconfigured", else: "ok"

      {_mode, address} ->
        case stripe_module.list_deposit_addresses("tempo") do
          {:ok, addresses} ->
            if String.downcase(address) in addresses, do: "ok", else: "mismatch"

          {:error, {status, _}} when status in [401, 403] ->
            "unauthorized"

          _ ->
            "unreachable"
        end
    end
  end

  @doc """
  Runs the check once, synchronously. Pure apart from the Stripe calls, which
  go through `stripe_module`.
  """
  def check(key, price_ids, deploy_env, stripe_module) do
    configured = Enum.reject(price_ids, &(&1 in [nil, ""]))

    case Lei.Stripe.Mode.of(key) do
      :malformed ->
        "malformed"

      :unconfigured ->
        if Lei.Stripe.Mode.production?(deploy_env), do: "unconfigured", else: "ok"

      _mode when configured == [] ->
        # A key with nothing to check it against is not evidence of anything.
        if Lei.Stripe.Mode.production?(deploy_env), do: "unconfigured", else: "ok"

      _mode ->
        configured
        |> Enum.map(&retrieve(stripe_module, &1))
        |> Kernel.++([checkout_readable(stripe_module)])
        |> worst()
    end
  end

  # Order matters: the most actionable failure wins when prices disagree.
  @severity [
    "malformed",
    "unconfigured",
    "unauthorized",
    "mismatch",
    "inactive",
    "unreachable",
    "pending",
    "ok"
  ]

  defp worst(results) do
    Enum.find(@severity, "ok", &(&1 in results))
  end

  # Classified by HTTP status, not by the error body: Stripe's 401 for a bad key
  # is an "invalid_request_error" with no code, indistinguishable by body from
  # other bad requests. 403 is a restricted key without read access to prices,
  # which is a key problem of the same kind.
  defp retrieve(stripe_module, price_id) do
    case stripe_module.retrieve_price(price_id) do
      {:ok, %{"active" => true}} -> "ok"
      {:ok, %{"active" => false}} -> "inactive"
      {:error, {404, _body}} -> "mismatch"
      {:error, {status, _body}} when status in [401, 403] -> "unauthorized"
      _ -> "unreachable"
    end
  end

  # Pro activation confirms payment by retrieving the Checkout Session
  # (Lei.Signup). A restricted key without that permission would strand every
  # paying customer on "could not confirm your payment" while prices, and so
  # this check, looked fine. No real session is needed to tell: an id that does
  # not exist is a 404 to a key that may read sessions and a 403 to one that
  # may not.
  @probe_session "cs_lei_permission_probe"

  defp checkout_readable(stripe_module) do
    case stripe_module.retrieve_checkout_session(@probe_session) do
      {:error, {404, _body}} -> "ok"
      {:error, {status, _body}} when status in [401, 403] -> "unauthorized"
      _ -> "unreachable"
    end
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    state = %{
      result: "pending",
      deposit: {nil, "pending"},
      config: Keyword.get(opts, :config, &config/0),
      recheck_ms: Keyword.get(opts, :recheck_ms, @recheck_ms),
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms)
    }

    send(self(), :check)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {_address, deposit} = state.deposit
    {:reply, worst([state.result, deposit]), state}
  end

  def handle_call({:deposit_confirmed?, address}, _from, state) do
    {:reply, state.deposit == {address, "ok"}, state}
  end

  @impl true
  def handle_info(:check, state) do
    {key, price_ids, deploy_env, stripe_module, address} = state.config.()

    # Stripe is called from inside this process, so a slow Stripe holds up
    # status/0 callers only until their 1s timeout, never the probe itself.
    result = safely(fn -> check(key, price_ids, deploy_env, stripe_module) end)

    deposit =
      {address && String.downcase(address),
       safely(fn -> check_deposit_address(key, address, deploy_env, stripe_module) end)}

    {_, deposit_result} = deposit

    if deposit_result not in ["ok", elem(state.deposit, 1)] do
      Logger.error("Stripe deposit address check: #{deposit_result}")
    end

    if result != "ok" and result != state.result do
      Logger.error("Stripe object check: #{result} (mode #{Lei.Stripe.Mode.of(key)})")
    end

    delay =
      if "unreachable" in [result, deposit_result], do: state.retry_ms, else: state.recheck_ms

    Process.send_after(self(), :check, delay)
    {:noreply, %{state | result: result, deposit: deposit}}
  end

  defp safely(fun) do
    fun.()
  rescue
    e ->
      Logger.warning("Stripe object check raised: #{Exception.message(e)}")
      "unreachable"
  end

  defp config do
    {
      Application.get_env(:lowendinsight, :stripe_secret_key),
      [
        Application.get_env(:lowendinsight, :stripe_pro_price_id),
        Application.get_env(:lowendinsight, :stripe_metered_price_id)
      ],
      Application.get_env(:lowendinsight, :deploy_env),
      Lei.Stripe.impl(),
      Application.get_env(:lowendinsight, :tempo_deposit_address)
    }
  end
end
