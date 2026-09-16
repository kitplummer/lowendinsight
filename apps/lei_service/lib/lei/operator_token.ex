defmodule Lei.OperatorToken do
  @moduledoc """
  Verifies an operator token: signature, and the claims that bound it.

  Both authentication paths called `Joken.verify/2`, which checks the
  signature and nothing else. A token whose `exp` had passed was accepted, and
  a token minted without `exp` was valid for as long as the signing secret
  lived -- and an operator token reaches every unbilled and operator-only
  route (security review, 2026-09-14).

  Three rules, because expiry only means something if all three hold:

    * the signature is ours;
    * `exp` is present -- a token without one never expires;
    * `exp` is in the future, and no further out than
      `:operator_token_max_lifetime_seconds`, so a token cannot be minted
      today that still works next year.
  """

  @default_max_lifetime_seconds 86_400

  @type reason :: :missing_exp | :expired | :lifetime_too_long | term()

  @spec verify(String.t()) :: {:ok, map()} | {:error, reason()}
  def verify(jwt) when is_binary(jwt) do
    with {:ok, claims} <- Joken.verify(jwt, signer()),
         {:ok, exp} <- fetch_exp(claims),
         :ok <- check_expiry(exp) do
      {:ok, claims}
    end
  end

  def verify(_), do: {:error, :invalid_token}

  @doc "The longest a token may be valid for, in seconds."
  def max_lifetime_seconds do
    Application.get_env(
      :lei_service,
      :operator_token_max_lifetime_seconds,
      @default_max_lifetime_seconds
    )
  end

  defp fetch_exp(claims) do
    case claims do
      %{"exp" => exp} when is_integer(exp) -> {:ok, exp}
      %{"exp" => exp} when is_binary(exp) -> parse_exp(exp)
      _ -> {:error, :missing_exp}
    end
  end

  defp parse_exp(exp) do
    case Integer.parse(exp) do
      {seconds, ""} -> {:ok, seconds}
      _ -> {:error, :missing_exp}
    end
  end

  defp check_expiry(exp) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    cond do
      exp <= now -> {:error, :expired}
      exp - now > max_lifetime_seconds() -> {:error, :lifetime_too_long}
      true -> :ok
    end
  end

  defp signer do
    Joken.Signer.create("HS256", Application.get_env(:lei_service, :jwt_secret, "lei_dev_secret"))
  end
end
