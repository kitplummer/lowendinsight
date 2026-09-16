defmodule Lei.PackageRepository do
  @moduledoc """
  Resolves a package coordinate to the repository to analyse.

  A batch request names packages (`ecosystem`, `package`, `version`); an
  analysis needs a repository URL. Each scanner already knew how to find one
  for its registry, but only inside a function that immediately analysed it,
  so a batch job could not ask the question on its own (ADR-004).

  Returns `{:ok, url}` or `{:error, reason}`, never a guess: an ecosystem this
  does not know is refused rather than resolved by pattern.
  """

  @doc """
  Resolve `package` in `ecosystem` to an https repository URL.

  Options:
    * `:get` - the HTTP GET, for tests. Defaults to `HTTPoison.get/1`
      through `Lei.HTTP.Retry`.
    * `:retry` - retry options. Defaults to 3 attempts 2s apart: a registry
      that is down should fail a job quickly, not hold a worker for the
      retry module's default 5 attempts 15s apart.
  """
  @spec resolve(String.t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error,
             :not_found
             | :no_repository
             | {:unsupported_ecosystem, String.t()}
             | {:unreachable, term()}
             | {:status, integer()}}
  def resolve(ecosystem, package, opts \\ []) do
    with {:ok, url, extract} <- registry(ecosystem, package),
         {:ok, body} <- fetch(url, opts) do
      case extract.(body) do
        nil -> {:error, :no_repository}
        repository -> normalize(repository)
      end
    end
  end

  defp registry("npm", package) do
    {:ok, "https://registry.npmjs.org/" <> URI.encode(package),
     fn body -> get_in(body, ["repository", "url"]) end}
  end

  defp registry("hex", package) do
    {:ok, "https://hex.pm/api/packages/" <> URI.encode(package),
     fn body ->
       links = get_in(body, ["meta", "links"]) || %{}
       downcased = for {k, v} <- links, into: %{}, do: {String.downcase(k), v}
       downcased["github"] || downcased["bitbucket"] || downcased["gitlab"]
     end}
  end

  defp registry("pypi", package) do
    {:ok, "https://pypi.org/pypi/" <> URI.encode(package) <> "/json",
     fn body ->
       urls = get_in(body, ["info", "project_urls"]) || %{}

       ["Code", "Source Code", "Source", "Repository"]
       |> Enum.find_value(&urls[&1])
       |> case do
         nil -> if repository?(urls["Homepage"]), do: urls["Homepage"]
         url -> url
       end
     end}
  end

  defp registry("cargo", package) do
    {:ok, "https://crates.io/api/v1/crates/" <> URI.encode(package),
     fn body -> get_in(body, ["crate", "repository"]) end}
  end

  defp registry(ecosystem, _package), do: {:error, {:unsupported_ecosystem, ecosystem}}

  @retry_defaults [max_attempts: 3, wait: 2_000]

  defp fetch(url, opts) do
    get = Keyword.get(opts, :get, &default_get/1)
    retry = Keyword.merge(@retry_defaults, Keyword.get(opts, :retry, []))

    case Lei.HTTP.Retry.request(fn -> get.(url) end, retry) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, :no_repository}
        end

      {:ok, %HTTPoison.Response{status_code: 404}} ->
        {:error, :not_found}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:status, status}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, {:unreachable, reason}}
    end
  end

  defp default_get(url) do
    HTTPoison.start()
    HTTPoison.get(url, [{"User-Agent", "lowendinsight"}], recv_timeout: 30_000)
  end

  # Registries record repositories in whatever form the package author wrote:
  # git+ssh, git://, a trailing .git. The analyzer clones over https.
  defp normalize(url) when is_binary(url) do
    normalized =
      url
      |> String.trim()
      |> String.replace_prefix("git+", "")
      |> String.replace_prefix("git://", "https://")
      |> String.replace_prefix("ssh://git@", "https://")
      |> String.replace_prefix("git@", "https://")
      |> String.replace_suffix(".git", "")
      |> String.replace_suffix("/", "")

    normalized =
      case normalized do
        "https://git@" <> rest -> "https://" <> rest
        other -> other
      end

    if repository?(normalized), do: {:ok, normalized}, else: {:error, :no_repository}
  end

  defp normalize(_), do: {:error, :no_repository}

  # A homepage is only worth analysing when it names a repository host.
  defp repository?(url) when is_binary(url) do
    String.match?(url, ~r{^https://(www\.)?(github\.com|gitlab\.com|bitbucket\.org)/[^/]+/[^/]+}) and
      not String.contains?(url, " ")
  end

  defp repository?(_), do: false
end
