defmodule Lei.HTTP.Retry do
  @moduledoc """
  Retries an HTTPoison request on transient failures.

  Replaces the `httpoison_retry` package, which has not been released since
  2019 and does not allow httpoison 2 or 3 (ADR-003, 0.10.0).

  A request is retried when it fails with a transport error that is likely to
  pass (`:timeout`, `:connect_timeout`, `:closed`, `:nxdomain`) or when the
  server answers 500. Anything else, including 404, is returned as it is.
  After the last attempt the last result is returned, never raised.

  Sleeps between attempts, so do not call it from a GenServer or a request
  handler with a deadline.
  """

  @transient_errors [:timeout, :connect_timeout, :closed, :nxdomain]

  @type result :: {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}

  @doc """
  Calls `request` until it succeeds or `max_attempts` calls have been made.

  Options:
    * `:max_attempts` - total calls, including the first (default 5)
    * `:wait` - milliseconds between attempts (default 15_000)
    * `:sleep` - the sleep function, for tests (default `Process.sleep/1`)
  """
  @spec request((-> result()), keyword()) :: result()
  def request(request, opts \\ []) when is_function(request, 0) do
    max_attempts = Keyword.get(opts, :max_attempts, 5)
    wait = Keyword.get(opts, :wait, 15_000)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)

    unless is_integer(max_attempts) and max_attempts >= 1 do
      raise ArgumentError,
            "max_attempts must be a positive integer, got: #{inspect(max_attempts)}"
    end

    attempt(request, 1, max_attempts, wait, sleep)
  end

  defp attempt(request, n, max_attempts, wait, sleep) do
    result = request.()

    if n < max_attempts and transient?(result) do
      sleep.(wait)
      attempt(request, n + 1, max_attempts, wait, sleep)
    else
      result
    end
  end

  @doc false
  def transient?({:error, %HTTPoison.Error{reason: reason}}), do: reason in @transient_errors
  def transient?({:ok, %HTTPoison.Response{status_code: 500}}), do: true
  def transient?(_), do: false
end
