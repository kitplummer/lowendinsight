defmodule LeiService.RemoteUrl do
  @moduledoc """
  Whether the service may clone a URL on a caller's behalf: https, to a host
  whose every address is public.

  The analyzer clones whatever it is given, and `Helpers.validate_url/1` --
  written for the command-line tool -- allows `file://` and any host that
  resolves. Through the web service that let anyone have it `git clone`
  loopback, cloud metadata or Fly's private network, or run git against a local
  path (security review, 2026-09-14). Decided 2026-09-15: public https only.

  Not covered here: git resolves the host
  again when it clones, so a name that changes answer between the two lookups
  is not caught; and git follows an initial HTTP redirect.
  """

  import Bitwise

  @type error :: {:error, String.t()}

  @doc """
  `:ok` or `{:error, reason}`. `opts[:resolve]` is `(host -> {:ok, [ip]} |
  {:error, term})`, for tests; by default both A and AAAA records are looked up.
  """
  @spec validate(term(), keyword()) :: :ok | error
  def validate(url, opts \\ [])

  def validate(url, opts) when is_binary(url) do
    # opts wins, then configuration, then real DNS. The configured hook exists
    # so the worker-time check can be driven in a test: `analyze/3` calls
    # validate/1 with no opts, and the case worth reproducing is precisely the
    # one where this check and the route's disagree (#257).
    resolve =
      Keyword.get(opts, :resolve) ||
        Application.get_env(:lei_service, :remote_url_resolver) ||
        (&resolve/1)

    with {:ok, uri} <- parse(url),
         :ok <- https(uri),
         :ok <- no_userinfo(uri),
         :ok <- default_port(uri),
         {:ok, host} <- host(uri),
         {:ok, addrs} <- addresses(host, resolve) do
      public(addrs)
    end
  end

  def validate(_url, _opts), do: {:error, "not a URL"}

  @doc "`:ok`, or the first URL refused with its reason."
  def validate_all(urls, opts \\ [])

  def validate_all(urls, opts) when is_list(urls) do
    Enum.reduce_while(urls, :ok, fn url, :ok ->
      case validate(url, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, %{url: url, reason: reason}}}
      end
    end)
  end

  def validate_all(_urls, _opts), do: {:error, %{url: nil, reason: "urls must be a list"}}

  defp parse(url) do
    {:ok, URI.parse(url)}
  rescue
    _ -> {:error, "not a URL"}
  end

  defp https(%URI{scheme: "https"}), do: :ok
  defp https(_), do: {:error, "only https URLs can be analyzed"}

  defp no_userinfo(%URI{userinfo: nil}), do: :ok
  defp no_userinfo(_), do: {:error, "credentials in the URL are not accepted"}

  # URI.parse fills in 443 for https when no port is written.
  defp default_port(%URI{port: 443}), do: :ok
  defp default_port(_), do: {:error, "only the default https port is accepted"}

  defp host(%URI{host: host}) when is_binary(host) and host != "", do: {:ok, host}
  defp host(_), do: {:error, "the URL has no host"}

  defp addresses(host, resolve) do
    case resolve.(host) do
      {:ok, [_ | _] = addrs} -> {:ok, addrs}
      _ -> {:error, "the host does not resolve"}
    end
  end

  # Every address, not any: a name with one public and one private record is
  # a name git may connect to privately.
  defp public(addrs) do
    if Enum.all?(addrs, &public?/1),
      do: :ok,
      else: {:error, "the host resolves to a non-public address"}
  end

  defp resolve(host) do
    charlist = String.to_charlist(host)

    v4 =
      case :inet.getaddrs(charlist, :inet) do
        {:ok, a} -> a
        _ -> []
      end

    v6 =
      case :inet.getaddrs(charlist, :inet6) do
        {:ok, a} -> a
        _ -> []
      end

    case v4 ++ v6 do
      [] -> {:error, :nxdomain}
      addrs -> {:ok, addrs}
    end
  end

  @doc false
  def public?({a, b, c, _d} = ip) when tuple_size(ip) == 4 do
    not (a == 0 or
           a == 10 or
           a == 127 or
           (a == 100 and b >= 64 and b <= 127) or
           (a == 169 and b == 254) or
           (a == 172 and b >= 16 and b <= 31) or
           (a == 192 and b == 168) or
           (a == 192 and b == 0 and (c == 0 or c == 2)) or
           (a == 198 and (b == 18 or b == 19)) or
           (a == 198 and b == 51 and c == 100) or
           (a == 203 and b == 0 and c == 113) or
           a >= 224)
  end

  def public?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: public?(v4(hi, lo))
  def public?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: public?(v4(hi, lo))
  def public?({0, 0, 0, 0, 0, 0, 0, _}), do: false

  def public?({first, second, _, _, _, _, _, _}) do
    not ((first &&& 0xFE00) == 0xFC00 or
           (first &&& 0xFFC0) == 0xFE80 or
           (first &&& 0xFF00) == 0xFF00 or
           (first == 0x2001 and second == 0x0DB8) or
           first == 0x0100)
  end

  def public?(_), do: false

  defp v4(hi, lo), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}
end
