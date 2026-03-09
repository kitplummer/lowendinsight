defmodule Lei.StripeBehaviour do
  @callback create_checkout_session(map()) :: {:ok, map()} | {:error, term()}
  @callback construct_webhook_event(String.t(), String.t(), String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback create_payment_intent(map()) :: {:ok, map()} | {:error, term()}
  @callback report_usage(String.t(), integer(), integer()) :: {:ok, map()} | {:error, term()}
  @callback retrieve_subscription(String.t()) :: {:ok, map()} | {:error, term()}
end

defmodule Lei.Stripe do
  @behaviour Lei.StripeBehaviour

  def impl do
    Application.get_env(:lowendinsight, :stripe_module, __MODULE__)
  end

  @impl true
  def create_checkout_session(params) do
    api_key = Application.get_env(:lowendinsight, :stripe_secret_key)

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
           [
             {"Authorization", "Bearer #{api_key}"},
             {"Content-Type", "application/x-www-form-urlencoded"}
           ]
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
    api_key = Application.get_env(:lowendinsight, :stripe_secret_key)

    body =
      URI.encode_query(%{
        "amount" => to_string(params.amount),
        "currency" => params.currency,
        "payment_method" => params.payment_method,
        "confirm" => "true",
        "return_url" =>
          params[:return_url] ||
            Application.get_env(:lowendinsight, :lei_base_url, "https://lowendinsight.fly.dev")
      })

    case HTTPoison.post(
           "https://api.stripe.com/v1/payment_intents",
           body,
           [
             {"Authorization", "Bearer #{api_key}"},
             {"Content-Type", "application/x-www-form-urlencoded"}
           ]
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
  def report_usage(subscription_item_id, quantity, timestamp) do
    api_key = Application.get_env(:lowendinsight, :stripe_secret_key)

    body =
      URI.encode_query(%{
        "quantity" => to_string(quantity),
        "timestamp" => to_string(timestamp),
        "action" => "set"
      })

    case HTTPoison.post(
           "https://api.stripe.com/v1/subscription_items/#{subscription_item_id}/usage_records",
           body,
           [
             {"Authorization", "Bearer #{api_key}"},
             {"Content-Type", "application/x-www-form-urlencoded"}
           ]
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
  def retrieve_subscription(subscription_id) do
    api_key = Application.get_env(:lowendinsight, :stripe_secret_key)

    case HTTPoison.get(
           "https://api.stripe.com/v1/subscriptions/#{subscription_id}",
           [
             {"Authorization", "Bearer #{api_key}"},
             {"Content-Type", "application/x-www-form-urlencoded"}
           ]
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
