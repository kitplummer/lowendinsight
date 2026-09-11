defmodule Lei.StripeBehaviour do
  @callback create_checkout_session(map()) :: {:ok, map()} | {:error, term()}
  @callback construct_webhook_event(String.t(), String.t(), String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback create_payment_intent(map()) :: {:ok, map()} | {:error, term()}
  @callback report_meter_event(String.t(), integer(), integer()) :: {:ok, map()} | {:error, term()}
  @callback retrieve_subscription(String.t()) :: {:ok, map()} | {:error, term()}
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
    Application.get_env(:lowendinsight, :stripe_module, __MODULE__)
  end

  def meter_event_name, do: @meter_event_name

  defp headers do
    api_key = Application.get_env(:lowendinsight, :stripe_secret_key)

    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Stripe-Version", @stripe_version}
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
  def construct_webhook_event(payload, signature, webhook_secret) do
    # Verify Stripe webhook signature
    timestamp_and_sigs = String.split(signature, ",")

    timestamp =
      Enum.find_value(timestamp_and_sigs, fn part ->
        case String.split(part, "=", parts: 2) do
          ["t", ts] -> ts
          _ -> nil
        end
      end)

    v1_sig =
      Enum.find_value(timestamp_and_sigs, fn part ->
        case String.split(part, "=", parts: 2) do
          ["v1", sig] -> sig
          _ -> nil
        end
      end)

    if is_nil(timestamp) or is_nil(v1_sig) do
      {:error, :invalid_signature}
    else
      signed_payload = "#{timestamp}.#{payload}"

      expected =
        :crypto.mac(:hmac, :sha256, webhook_secret, signed_payload) |> Base.encode16(case: :lower)

      if secure_compare(expected, v1_sig) do
        {:ok, Poison.decode!(payload)}
      else
        {:error, :invalid_signature}
      end
    end
  end

  @impl true
  def create_payment_intent(params) do

    body =
      URI.encode_query(%{
        "amount" => to_string(params.amount),
        "currency" => params.currency,
        "payment_method" => params.payment_method,
        "confirm" => "true",
        "return_url" =>
          params[:return_url] ||
            # Production always configures :lei_base_url in runtime.exs; this
            # fallback is for dev and test. Kept identical to the one in
            # Lei.Web.Router so the two cannot disagree about where a customer
            # is sent after paying.
            Application.get_env(:lowendinsight, :lei_base_url, "http://localhost:4000")
      })

    case HTTPoison.post(
           "https://api.stripe.com/v1/payment_intents",
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
  @doc """
  Reports usage as a billing meter event, keyed by customer.

  Meter events are **additive** -- Stripe sums them over the period. The
  endpoint this replaced took `action: "set"`, which replaced the period total,
  so each report had to carry the cumulative figure. Sending a cumulative value
  here would compound: report 100, then 250, then 400, and Stripe bills 750.

  So callers must send the cost of *this* usage only, never a running total.
  """
  def report_meter_event(stripe_customer_id, value, timestamp) do
    body =
      URI.encode_query(%{
        "event_name" => @meter_event_name,
        "timestamp" => to_string(timestamp),
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

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_a, _b), do: false
end
