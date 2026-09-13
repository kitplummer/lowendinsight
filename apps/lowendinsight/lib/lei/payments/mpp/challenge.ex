defmodule Lei.Payments.Mpp.Challenge do
  @moduledoc """
  The `WWW-Authenticate: Payment` challenge a 402 carries.

  MPP is an HTTP authentication scheme (draft-ryan-httpauth-payment), not a
  bespoke JSON envelope: the server answers 402 with a challenge, the client
  retries with `Authorization: Payment`, and the server returns a
  `Payment-Receipt`. Building on the auth-scheme grammar rather than a body
  format is what lets one endpoint serve paying and non-paying callers.

      WWW-Authenticate: Payment id="...", realm="...", method="...",
          intent="charge", expires="...", request="<base64url JSON>"

  `id` is the part that carries weight. The credential echoes it back, and
  checking that echo is what stops a proof bought for one resource being spent
  on another -- cross-resource substitution, which is a documented x402 flaw
  precisely because its signatures were context-agnostic.
  """

  @enforce_keys [:id, :realm, :method, :intent, :request]
  defstruct [:id, :realm, :method, :intent, :request, :expires, :description, :opaque]

  @type t :: %__MODULE__{
          id: String.t(),
          realm: String.t(),
          method: String.t(),
          intent: String.t(),
          request: map(),
          expires: DateTime.t() | nil,
          description: String.t() | nil,
          opaque: map() | nil
        }

  @doc """
  Builds a challenge for a purchase of `credits`.

  `amount` is a string throughout. The spec serialises `request` with JCS, and
  a float that renders as 14.980000000000001 in one language and 14.98 in
  another breaks the echo comparison for a reason nobody would find quickly.
  """
  def new(opts) do
    %__MODULE__{
      id: Keyword.get_lazy(opts, :id, &generate_id/0),
      realm: Keyword.fetch!(opts, :realm),
      method: Keyword.get(opts, :method, "stripe"),
      intent: Keyword.get(opts, :intent, "charge"),
      request: Keyword.fetch!(opts, :request),
      expires: Keyword.get(opts, :expires),
      description: Keyword.get(opts, :description),
      opaque: Keyword.get(opts, :opaque)
    }
  end

  @doc """
  Renders the header value.

  Parameter order is fixed rather than map iteration order, so the same
  challenge always produces the same bytes -- a header that shuffles between
  responses is unreadable in a log and untestable without sorting first.
  """
  def to_header(%__MODULE__{} = c) do
    params =
      [
        {"id", c.id},
        {"realm", c.realm},
        {"method", c.method},
        {"intent", c.intent}
      ] ++
        optional("expires", c.expires && DateTime.to_iso8601(c.expires)) ++
        optional("description", c.description) ++
        [{"request", encode_json(c.request)}] ++
        optional("opaque", c.opaque && encode_json(c.opaque))

    "Payment " <> Enum.map_join(params, ", ", fn {k, v} -> ~s(#{k}="#{escape(v)}") end)
  end

  @doc """
  Parses a header value back into a challenge.

  Needed to verify the echo in a credential, and to test that what goes out
  comes back the same.
  """
  def from_header("Payment " <> params) do
    parsed = parse_params(params)

    with {:ok, id} <- fetch(parsed, "id"),
         {:ok, realm} <- fetch(parsed, "realm"),
         {:ok, method} <- fetch(parsed, "method"),
         {:ok, intent} <- fetch(parsed, "intent"),
         {:ok, request_b64} <- fetch(parsed, "request"),
         {:ok, request} <- decode_json(request_b64) do
      {:ok,
       %__MODULE__{
         id: id,
         realm: realm,
         method: method,
         intent: intent,
         request: request,
         expires: parse_expires(parsed["expires"]),
         description: parsed["description"],
         opaque: parsed["opaque"] && decode_json!(parsed["opaque"])
       }}
    end
  end

  def from_header(_), do: {:error, :not_a_payment_challenge}

  @doc """
  Whether the challenge has passed its expiry.

  A challenge with no expiry never expires, which is the spec's default and is
  a decision the caller makes by omitting it rather than something to infer.
  """
  def expired?(challenge, now \\ DateTime.utc_now())

  def expired?(%__MODULE__{expires: nil}, _now), do: false

  def expired?(%__MODULE__{expires: expires}, now),
    do: DateTime.compare(now, expires) == :gt

  @doc """
  base64url of the JCS-canonical JSON, as the spec requires.

  Canonical means sorted keys and no whitespace: the credential echoes this
  back and the comparison is byte-for-byte, so any encoder disagreement about
  key order would reject a legitimate payment.
  """
  def encode_json(value) do
    value
    |> canonical_json()
    |> Base.url_encode64(padding: false)
  end

  def decode_json(b64) do
    with {:ok, json} <- Base.url_decode64(b64, padding: false),
         {:ok, map} <- Poison.decode(json) do
      {:ok, map}
    else
      _ -> {:error, :malformed_request}
    end
  end

  def decode_json!(b64) do
    {:ok, map} = decode_json(b64)
    map
  end

  # Emits sorted-key JSON directly rather than sorting and re-encoding.
  #
  # The obvious version -- sort the pairs, Enum.into a map, hand it to an
  # encoder -- does nothing: putting pairs back into a map re-orders them.
  # Elixir maps of 32 keys or fewer happen to iterate sorted, so the mistake is
  # invisible until a request has 33 keys, at which point the bytes stop
  # matching what the payment network signed and a legitimate payment is
  # refused.
  #
  # Only object key order is handled here. The request carries no floats --
  # amounts are strings, for exactly the reason JCS specifies a number format.
  defp canonical_json(%{} = map) do
    inner =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {k, v} -> Poison.encode!(k) <> ":" <> canonical_json(v) end)

    "{" <> inner <> "}"
  end

  defp canonical_json(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"

  defp canonical_json(other), do: Poison.encode!(other)
  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp optional(_key, nil), do: []
  defp optional(key, value), do: [{key, value}]

  defp escape(value), do: value |> to_string() |> String.replace("\"", "\\\"")

  defp fetch(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_parameter, key}}
    end
  end

  defp parse_expires(nil), do: nil

  defp parse_expires(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_params(params) do
    Regex.scan(~r/([a-zA-Z0-9_-]+)\s*=\s*"((?:[^"\\]|\\.)*)"/, params)
    |> Map.new(fn [_, k, v] -> {k, String.replace(v, "\\\"", "\"")} end)
  end
end
