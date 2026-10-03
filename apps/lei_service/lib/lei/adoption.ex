defmodule Lei.Adoption do
  @moduledoc """
  Which clients actually call the analysis, counted per day.

  The MCP server exists on the theory that an agent will reach for this while
  deciding what to depend on. Nothing measured whether that happens, so the
  question could only be answered with an opinion — and the answer decides
  whether the distribution work is worth continuing at all.

  ## Buckets, not user agents

  The client comes from a request header, which means the label values are
  chosen by whoever is calling. A counter labelled with the raw `User-Agent`
  would let one caller mint unbounded label values and make `/metrics` grow
  until the scrape times out, taking every other signal with it. So a user agent
  is mapped to one of a fixed set of buckets, and anything unrecognised is
  `other`. The set is the ceiling on cardinality.

  ## Per day, in Redis

  `INCR` on a dated key with a TTL. Durable across deploys — a boot-scoped
  counter resets every time we ship, which for "has anyone used this yet" is the
  wrong answer rather than a smaller one — and small enough not to matter
  against the cache's budget: a handful of integers per client per day.

  Recording never fails a request. The counter is worth less than the analysis
  it is counting, so a Redis that cannot be written is logged and ignored. The
  reading side is where that has to be visible: `window/1` returns `{:error, _}`
  rather than zeros, because "nobody has called this" and "we could not tell" are
  opposite findings.
  """

  require Logger

  # The ceiling on label cardinality. A user agent that matches none of these is
  # `other`; a request with no user agent at all is `none`. Both are buckets, so
  # neither disappears from the count.
  @buckets [
    {~r/^lowendinsight-mcp\//i, "mcp"},
    {~r/^lowendinsight-cli\//i, "cli"},
    {~r/^lowendinsight\b/i, "internal"},
    {~r/\b(claude|gpt|openai|anthropic|cursor|copilot|windsurf|devin)\b/i, "agent"},
    {~r/^(curl|wget|httpie|python-requests|got|axios|node-fetch)\b/i, "script"},
    {~r/\b(mozilla|chrome|safari|firefox|edge)\b/i, "browser"}
  ]

  @retention_days 90

  @doc """
  The bucket a user agent falls in. Never the user agent itself.
  """
  @spec bucket(String.t() | nil) :: String.t()
  def bucket(nil), do: "none"
  def bucket(""), do: "none"

  def bucket(user_agent) when is_binary(user_agent) do
    Enum.find_value(@buckets, "other", fn {pattern, name} ->
      if Regex.match?(pattern, user_agent), do: name
    end)
  end

  def bucket(_), do: "other"

  @doc """
  The buckets that exist, so a reader can tell an absent bucket from a zero one.
  """
  @spec buckets() :: [String.t()]
  def buckets, do: ["mcp", "cli", "internal", "agent", "script", "browser", "other", "none"]

  @doc """
  Count one call from `user_agent`. Returns `:ok` whatever happens.
  """
  @spec record(String.t() | nil, Date.t()) :: :ok
  def record(user_agent, on \\ Date.utc_today()) do
    key = key(bucket(user_agent), on)

    case Redix.pipeline(conn(), [["INCR", key], ["EXPIRE", key, @retention_days * 86_400]]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        # Deliberately swallowed. A missed count is a worse measurement; a
        # failed analysis is a worse product.
        Logger.warning("could not record adoption for #{key}: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Calls per bucket over the last `days`, inclusive of today.

  `{:ok, %{bucket => count}}` or `{:error, reason}`. Every bucket is present,
  including the ones at zero: a bucket missing from the map would read as "not a
  thing we count" rather than "nothing came from there".
  """
  @spec window(pos_integer()) :: {:ok, %{String.t() => non_neg_integer()}} | {:error, term()}
  def window(days) when is_integer(days) and days > 0 do
    today = Date.utc_today()
    dates = for offset <- 0..(days - 1), do: Date.add(today, -offset)
    pairs = for b <- buckets(), d <- dates, do: {b, key(b, d)}

    case Redix.pipeline(conn(), Enum.map(pairs, fn {_b, key} -> ["GET", key] end)) do
      {:ok, values} when length(values) == length(pairs) ->
        totals =
          pairs
          |> Enum.zip(values)
          |> Enum.reduce(Map.new(buckets(), &{&1, 0}), fn {{bucket, _key}, value}, acc ->
            Map.update!(acc, bucket, &(&1 + to_count(value)))
          end)

        {:ok, totals}

      {:ok, _} ->
        {:error, :unexpected_reply_count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_count(nil), do: 0

  defp to_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp to_count(_), do: 0

  defp key(bucket, date), do: "adoption:#{bucket}:#{Date.to_iso8601(date)}"

  defp conn, do: Application.get_env(:lei_service, :redix_name, :redix)
end
