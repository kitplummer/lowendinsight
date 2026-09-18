defmodule Lei.StripeBehaviour do
  @callback create_checkout_session(map()) :: {:ok, map()} | {:error, term()}
  @callback construct_webhook_event(String.t(), String.t(), String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback create_payment_intent(map()) :: {:ok, map()} | {:error, term()}
  @callback confirm_shared_payment_token(map()) ::
              {:ok, map()} | {:error, {pos_integer(), map()}} | {:error, term()}
  @callback report_meter_event(String.t(), integer(), integer(), String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback retrieve_subscription(String.t()) :: {:ok, map()} | {:error, term()}
  @callback retrieve_checkout_session(String.t()) ::
              {:ok, map()} | {:error, {pos_integer(), map()}} | {:error, term()}
  # Errors carry the HTTP status, unlike the callbacks above: the caller tells
  # "no such price" (404) from "bad key" (401) by it, and the bodies do not.
  # Crypto deposit addresses and transaction verification are preview APIs:
  # the pinned version rejects them as unknown parameters (observed, #144).
  @callback create_crypto_verification_intent(map()) ::
              {:ok, map()} | {:error, {pos_integer(), map()}} | {:error, term()}
  @callback list_payment_intents(created_gte :: integer(), starting_after :: String.t() | nil) ::
              {:ok, map()} | {:error, term()}
  @callback create_refund(map()) :: {:ok, map()} | {:error, term()}
  @callback retrieve_payment_intent(String.t()) ::
              {:ok, map()} | {:error, {pos_integer(), map()}} | {:error, term()}
  @callback list_deposit_addresses(String.t()) ::
              {:ok, [String.t()]} | {:error, {pos_integer(), map()}} | {:error, term()}
  @callback retrieve_price(String.t()) ::
              {:ok, map()} | {:error, {pos_integer(), map()}} | {:error, term()}
end

defmodule Lei.Stripe do
  @behaviour Lei.StripeBehaviour

  # Pinned deliberately. With no Stripe-Version header every request runs at
  # whatever Stripe has set as the account default, so they can change the
  # behaviour of this integration without a deploy. The legacy usage-records
  # endpoint this module used to call was removed in exactly that way.
  @stripe_version "2026-02-25.clover"

  # The meter this reports into. Its value unit is a tenth of a cent ($0.001),
  # chosen so every ADR-001 rate is an integer: a cache hit ($0.005) is 5 units
  # and a cache miss ($0.05) is 50. Cents alone would make a hit 0.5 units.
  @meter_event_name "analysis_cost"

  def impl do
    Application.get_env(:lei_service, :stripe_module, __MODULE__)
  end

  def meter_event_name, do: @meter_event_name

  # Only for the preview endpoints below. Everything else stays on the pinned
  # version so a preview's changes cannot reach the rest of the integration.
  @stripe_preview_version "2026-07-29.preview"

  defp headers(version \\ @stripe_version) do
    api_key = Application.get_env(:lei_service, :stripe_secret_key)

    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Stripe-Version", version}
    ]
  end

  @impl true
  def create_checkout_session(params) do
    metered_price_id = params[:metered_price_id]

    base_params = %{
      "mode" => "subscription",
      "payment_method_types[0]" => "card",
      "line_items[0][price]" => params.price_id,
      "line_items[0][quantity]" => "1",
      "success_url" => params.success_url,
      "cancel_url" => params.cancel_url,
      "metadata[org_id]" => to_string(params.org_id)
    }

    # Add metered usage price as second line item if configured
    base_params =
      if metered_price_id do
        Map.put(base_params, "line_items[1][price]", metered_price_id)
      else
        base_params
      end

    body = URI.encode_query(base_params)

    case HTTPoison.post(
           "https://api.stripe.com/v1/checkout/sessions",
           body,
           headers()
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        {:ok, Poison.decode!(resp_body)}

      {:ok, %HTTPoison.Response{body: resp_body}} ->
        {:error, Poison.decode!(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  # Stripe's own libraries allow five minutes. Beyond it a signed delivery is
  # treated as a replay: the signature proves Stripe sent it once, not that it
  # is being sent now.
  @webhook_tolerance_seconds 300

  def construct_webhook_event(payload, signature, webhook_secret) do
    parts =
      signature
      |> String.split(",")
      |> Enum.map(&String.split(&1, "=", parts: 2))

    timestamp =
      Enum.find_value(parts, fn
        [k, v] when k == "t" -> v
        _ -> nil
      end)

    # Every v1, not the first. During a secret rotation Stripe signs with both
    # the old and the new secret, and either may come first.
    v1_sigs = for [k, v] <- parts, k == "v1", do: v

    with ts when is_binary(ts) <- timestamp,
         [_ | _] <- v1_sigs,
         {ts_int, ""} <- Integer.parse(ts),
         expected =
           :crypto.mac(:hmac, :sha256, webhook_secret, "#{ts}.#{payload}")
           |> Base.encode16(case: :lower),
         true <- Enum.any?(v1_sigs, &secure_compare(expected, &1)) || :invalid_signature,
         true <- within_tolerance?(ts_int) || :timestamp_outside_tolerance do
      decode_event(payload)
    else
      :timestamp_outside_tolerance -> {:error, :timestamp_outside_tolerance}
      _ -> {:error, :invalid_signature}
    end
  end

  defp within_tolerance?(timestamp) do
    abs(System.system_time(:second) - timestamp) <= @webhook_tolerance_seconds
  end

  defp decode_event(payload) do
    case Poison.decode(payload) do
      {:ok, %{} = event} -> {:ok, event}
      _ -> {:error, :invalid_payload}
    end
  end

  @impl true
  def create_payment_intent(params) do
    {body, _extra_headers} = payment_intent_request(params)

    case HTTPoison.post(
           "https://api.stripe.com/v1/payment_intents",
           body,
           payment_intent_headers(params)
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        {:ok, Poison.decode!(resp_body)}

      {:ok, %HTTPoison.Response{body: resp_body}} ->
        {:error, Poison.decode!(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @doc """
  Reports usage as a billing meter event, keyed by customer.

  Meter events are **additive** -- Stripe sums them over the period. The
  endpoint this replaced took `action: "set"`, which replaced the period total,
  so each report had to carry the cumulative figure. Sending a cumulative value
  here would compound: report 100, then 250, then 400, and Stripe bills 750.

  So callers must send the cost of *this* usage only, never a running total.

  `identifier` is Stripe's deduplication key. Sending the same one twice is a
  no-op rather than a double charge, which matters because this is called from
  a Task: anything that retries it -- now or later, deliberately or via an
  at-least-once queue -- would otherwise bill the customer twice, silently.
  """
  def report_meter_event(stripe_customer_id, value, timestamp, identifier) do
    body =
      URI.encode_query(%{
        "event_name" => @meter_event_name,
        "timestamp" => to_string(timestamp),
        "identifier" => identifier,
        "payload[stripe_customer_id]" => stripe_customer_id,
        "payload[value]" => to_string(value)
      })

    case HTTPoison.post("https://api.stripe.com/v1/billing/meter_events", body, headers()) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        {:ok, Poison.decode!(resp_body)}

      {:ok, %HTTPoison.Response{body: resp_body}} ->
        {:error, Poison.decode!(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def retrieve_subscription(subscription_id) do
    case HTTPoison.get(
           "https://api.stripe.com/v1/subscriptions/#{subscription_id}",
           headers()
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        {:ok, Poison.decode!(resp_body)}

      {:ok, %HTTPoison.Response{body: resp_body}} ->
        {:error, Poison.decode!(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Charges an agent's Shared Payment Token, confirming immediately.

  Separate from `create_payment_intent/1` because the token is not a payment
  method, and passing it as one fails: Stripe answers `payment_method=spt_...`
  with "No such PaymentMethod". That is what #131 shipped, under tests that
  mocked this boundary and so asserted the wrong call faithfully (#143).
  """
  @impl true
  def confirm_shared_payment_token(params) do
    {body, extra_headers} = shared_payment_token_request(params)

    case HTTPoison.post(
           "https://api.stripe.com/v1/payment_intents",
           body,
           headers() ++ extra_headers
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        {:ok, Poison.decode!(resp_body)}

      {:ok, %HTTPoison.Response{status_code: status, body: resp_body}} ->
        {:error, {status, decode_or_raw(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The request `confirm_shared_payment_token/1` sends, as `{form_body, headers}`.

  Public so the exact bytes are testable; this is where the defect was.

    * `payment_method_data[shared_payment_granted_token]` -- the documented
      parameter. Confirmed against sandbox: succeeds synchronously
    * redirects disallowed -- an agent cannot complete a redirect, so a method
      needing one should fail here rather than sit in `requires_action`
    * no `return_url` -- only meaningful with redirects
    * `Idempotency-Key` -- an SPT is single-use. Retrying without the key
      creates a second intent, which Stripe refuses as "deactivated", so an
      agent retrying after a timeout is refused after paying. With the key
      the retry returns the intent that took the money
  """
  def shared_payment_token_request(params) do
    metadata =
      for {k, v} <- Map.get(params, :metadata, %{}), into: %{} do
        {"metadata[#{k}]", to_string(v)}
      end

    body =
      %{
        "amount" => to_string(params.amount),
        "currency" => params.currency,
        "payment_method_data[shared_payment_granted_token]" => params.spt,
        "confirm" => "true",
        "automatic_payment_methods[enabled]" => "true",
        "automatic_payment_methods[allow_redirects]" => "never"
      }
      |> Map.merge(metadata)
      |> URI.encode_query()

    {body, [{"Idempotency-Key", params.idempotency_key}]}
  end

  @doc """
  Asks Stripe to verify an on-chain transfer to one of our deposit addresses.

  Asynchronous: the intent is created `processing` whatever the hash, and a
  real transfer moves to `succeeded` or `requires_payment_method` within
  seconds. Stripe checks the transfer paid one of our addresses the claimed
  amount -- a transfer elsewhere declines `invalid_payment_information`, a
  wrong amount `invalid_amount`. A hash that does not exist stays `processing`
  (all observed in sandbox, #144).
  """
  @impl true
  def create_crypto_verification_intent(params) do
    {body, extra_headers} = crypto_verification_request(params)

    post_form("/v1/payment_intents", body, headers(@stripe_preview_version) ++ extra_headers)
  end

  @doc "The request `create_crypto_verification_intent/1` sends, as `{form_body, headers}`."
  def crypto_verification_request(params) do
    metadata =
      for {k, v} <- Map.get(params, :metadata, %{}), into: %{} do
        {"metadata[#{k}]", to_string(v)}
      end

    body =
      %{
        "amount" => to_string(params.amount),
        "currency" => "usd",
        "confirm" => "true",
        "payment_method_types[]" => "crypto",
        "payment_method_data[type]" => "crypto",
        "payment_method_options[crypto][mode]" => "transaction_verification",
        "payment_method_options[crypto][transaction_verification_options][network]" =>
          params.network,
        "payment_method_options[crypto][transaction_verification_options][transaction_hash]" =>
          params.transaction_hash
      }
      |> Map.merge(metadata)
      |> URI.encode_query()

    {body, [{"Idempotency-Key", params.idempotency_key}]}
  end

  @doc false
  # The request create_payment_intent/1 sends, separated so its bytes can be
  # asserted without a network (as shared_payment_token_request/1).
  #
  # `Idempotency-Key` is required, not optional. This was the one money-moving
  # call without one: an agent retrying /acp/checkout/:id/complete after a
  # timeout created a second real charge, because the session-state guard only
  # helps once the first call has returned, and a timeout is exactly when it
  # has not. Required rather than defaulted so a new caller cannot omit it
  # silently -- a missing key here is a duplicate charge, which is the failure
  # nobody notices until a customer says so.
  def payment_intent_request(params) do
    metadata =
      for {k, v} <- Map.get(params, :metadata, %{}), into: %{} do
        {"metadata[#{k}]", to_string(v)}
      end

    body =
      URI.encode_query(
        Map.merge(metadata, %{
          "amount" => to_string(params.amount),
          "currency" => params.currency,
          "payment_method" => params.payment_method,
          "confirm" => "true",
          # Production always configures :lei_base_url in runtime.exs; this
          # fallback is for dev and test. Kept identical to the one in
          # Lei.Web.Router so the two cannot disagree about where a customer
          # is sent after paying.
          "return_url" =>
            params[:return_url] ||
              Application.get_env(:lei_service, :lei_base_url, "http://localhost:4000")
        })
      )

    {body, [{"Idempotency-Key", params.idempotency_key}]}
  end

  @doc false
  # The complete header list create_payment_intent/1 posts.
  #
  # Assembled here rather than inline at the call site so it can be asserted.
  # The defect was not in building the key -- that half looked right -- but in
  # the caller destructuring the request as `{body, _}` and posting bare
  # `headers()`, discarding it. A header dropped after it is built is the same
  # as one never built, and no test of the request builder alone can see the
  # difference.
  def payment_intent_headers(params) do
    {_body, extra} = payment_intent_request(params)
    headers() ++ extra
  end

  @impl true
  def list_payment_intents(created_gte, starting_after) do
    get_json(
      list_payment_intents_path(created_gte, starting_after),
      headers(@stripe_preview_version)
    )
  end

  @doc false
  def list_payment_intents_path(created_gte, starting_after) do
    query =
      [
        {"limit", "100"},
        {"created[gte]", to_string(created_gte)},
        {"expand[]", "data.latest_charge"}
      ] ++ if(starting_after, do: [{"starting_after", starting_after}], else: [])

    "/v1/payment_intents?" <> URI.encode_query(query)
  end

  @impl true
  def create_refund(params) do
    {body, extra_headers} = refund_request(params)

    "https://api.stripe.com/v1/refunds"
    |> HTTPoison.post(body, headers() ++ extra_headers, recv_timeout: 30_000)
    |> json_result()
  end

  @doc false
  # Keyed: an agent that retries a refund after a timeout must reach the same
  # refund, not make a second one (Lei.Operations.refund/1).
  def refund_request(params) do
    metadata =
      for {k, v} <- Map.get(params, :metadata, %{}), into: %{} do
        {"metadata[#{k}]", to_string(v)}
      end

    fields =
      %{"payment_intent" => params.payment_intent}
      |> then(fn f ->
        if params[:amount], do: Map.put(f, "amount", to_string(params.amount)), else: f
      end)
      |> Map.merge(metadata)

    {URI.encode_query(fields), [{"Idempotency-Key", params.idempotency_key}]}
  end

  @impl true
  def retrieve_payment_intent(id) do
    get_json(
      "/v1/payment_intents/#{URI.encode_www_form(id)}?expand[]=latest_charge",
      headers(@stripe_preview_version)
    )
  end

  @impl true
  def list_deposit_addresses(network) do
    case get_json(
           "/v1/crypto/deposit_addresses?network=#{URI.encode_www_form(network)}&limit=100",
           headers(@stripe_preview_version)
         ) do
      {:ok, %{"data" => data}} when is_list(data) ->
        {:ok, Enum.map(data, &String.downcase(&1["address"] || ""))}

      {:ok, _} ->
        {:error, :unexpected_response}

      error ->
        error
    end
  end

  defp post_form(path, body, headers) do
    "https://api.stripe.com"
    |> Kernel.<>(path)
    |> HTTPoison.post(body, headers, recv_timeout: 30_000)
    |> json_result()
  end

  defp get_json(path, headers) do
    "https://api.stripe.com"
    |> Kernel.<>(path)
    |> HTTPoison.get(headers, recv_timeout: 30_000)
    |> json_result()
  end

  defp json_result({:ok, %HTTPoison.Response{status_code: 200, body: body}}),
    do: {:ok, Poison.decode!(body)}

  defp json_result({:ok, %HTTPoison.Response{status_code: status, body: body}}),
    do: {:error, {status, decode_or_raw(body)}}

  defp json_result({:error, reason}), do: {:error, reason}

  @impl true
  def retrieve_checkout_session(session_id) do
    get_json("/v1/checkout/sessions/#{URI.encode_www_form(session_id)}", headers())
  end

  @impl true
  def retrieve_price(price_id) do
    case HTTPoison.get(
           "https://api.stripe.com/v1/prices/#{URI.encode_www_form(price_id)}",
           headers()
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        {:ok, Poison.decode!(resp_body)}

      {:ok, %HTTPoison.Response{status_code: status, body: resp_body}} ->
        {:error, {status, decode_or_raw(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A proxy or load balancer error page is not JSON, and must not turn a
  # classifiable status into a crash.
  defp decode_or_raw(body) do
    case Poison.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{"raw" => body}
    end
  end

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_a, _b), do: false
end
