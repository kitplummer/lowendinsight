defmodule Lei.Payments.Mpp.Credential do
  @moduledoc """
  The `Authorization: Payment` credential a client retries with.

      Authorization: Payment <base64url of {"challenge": …, "source": …, "payload": …}>

  The `challenge` object echoes the parameters the server issued. Checking that
  echo against what was actually issued is the whole defence against
  cross-resource substitution -- buying a cheap resource and spending the proof
  on an expensive one. It is a documented x402 flaw, and the root cause named
  across the papers is signatures that carry no context about what they are
  paying for.

  So `matches?/2` is not a formality. A credential that verifies against the
  payment network but echoes a different challenge is a valid payment for
  something else.
  """

  alias Lei.Payments.Mpp.Challenge

  @enforce_keys [:challenge, :payload]
  defstruct [:challenge, :payload, :source]

  @type t :: %__MODULE__{challenge: map(), payload: map(), source: String.t() | nil}

  @doc """
  Parses the header value.
  """
  def from_header("Payment " <> encoded) do
    with {:ok, json} <- decode64(encoded),
         {:ok, %{"challenge" => challenge, "payload" => payload} = decoded}
         when is_map(challenge) and is_map(payload) <- decode_json(json) do
      {:ok,
       %__MODULE__{
         challenge: challenge,
         payload: payload,
         source: Map.get(decoded, "source")
       }}
    else
      {:ok, _} -> {:error, :malformed_credential}
      error -> error
    end
  end

  def from_header(nil), do: {:error, :no_credential}
  def from_header(_), do: {:error, :not_a_payment_credential}

  @doc """
  Renders a credential, for tests and for any client we write.
  """
  def to_header(%__MODULE__{} = c) do
    payload =
      %{"challenge" => c.challenge, "payload" => c.payload}
      |> then(fn m -> if c.source, do: Map.put(m, "source", c.source), else: m end)

    "Payment " <> (payload |> Poison.encode!() |> Base.url_encode64(padding: false))
  end

  @doc """
  Whether the credential echoes the challenge that was actually issued.

  Compares the identifying fields rather than the whole object: a client may
  legitimately include fields we did not send, but it may not disagree about
  which challenge this is, what it costs, or what method settles it.

  `request` is compared as the canonical encoding rather than as a decoded map,
  because that is what the payment network signed over. Comparing decoded maps
  would accept a re-serialisation that changed the bytes.
  """
  def matches?(%__MODULE__{challenge: echoed}, %Challenge{} = issued) do
    echoed["id"] == issued.id and
      echoed["realm"] == issued.realm and
      echoed["method"] == issued.method and
      echoed["intent"] == issued.intent and
      request_matches?(echoed["request"], issued.request)
  end

  defp request_matches?(nil, _issued), do: false

  defp request_matches?(echoed, issued) when is_binary(echoed),
    do: echoed == Challenge.encode_json(issued)

  # Some clients echo the request decoded rather than as the encoded string.
  # Accepted, but only if it canonicalises to the same bytes.
  defp request_matches?(echoed, issued) when is_map(echoed),
    do: Challenge.encode_json(echoed) == Challenge.encode_json(issued)

  defp request_matches?(_, _), do: false

  defp decode64(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, json} -> {:ok, json}
      :error -> {:error, :malformed_credential}
    end
  end

  defp decode_json(json) do
    case Poison.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :malformed_credential}
    end
  end
end
