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

  @doc """
  The repository URL and the declared dependencies, from **one** fetch.

  `resolve/3` and `dependencies/3` each request the same registry document.
  Calling both costs two round trips per package, which for a 400-package
  manifest is 800 requests where 400 would do (#263).

  Either field is `nil` when that part could not be read: a package with no
  repository link still has dependencies worth knowing, and an ecosystem whose
  dependency shape is unhandled still has a repository to analyse. Returning a
  pair rather than failing on the first missing half keeps them independent.
  """
  @spec describe(String.t(), String.t(), keyword()) ::
          {:ok, %{repository: String.t() | nil, dependencies: [String.t()] | nil}}
          | {:error, term()}
  def describe(ecosystem, package, opts \\ []) do
    with {:ok, url, extract} <- registry(ecosystem, package),
         {:ok, body} <- fetch(url, opts) do
      repository =
        case extract.(body) do
          nil ->
            nil

          found ->
            case normalize(found) do
              {:ok, normalized} -> normalized
              _ -> nil
            end
        end

      {:ok, %{repository: repository, dependencies: declared(ecosystem, body)}}
    end
  end

  @doc """
  The packages this one declares a dependency on, from the same registry
  response `resolve/3` already fetches (#263).

  Blast radius is not health: a dead dependency in a test helper and a dead
  dependency on the request path score identically by metric counts, and only
  the second is worth waking up for. In-degree within a customer's own manifest
  is a proxy for that, and it needs these edges.

  The request carries none — `valid_dependency?/1` accepts only ecosystem,
  package and version — so the graph has to come from somewhere. It comes from
  a field we were already receiving and discarding, which is the same shape as
  `github_trending` reading `size` and throwing away `pushed_at`.

  `{:ok, [names]}` or `{:error, reason}`. An ecosystem whose registry shape is
  not handled returns `{:error, :unsupported}` rather than an empty list:
  "declares nothing" and "we did not look" must not read alike, or a package
  whose edges we cannot see appears to have none and sorts as peripheral.
  """
  @spec dependencies(String.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def dependencies(ecosystem, package, opts \\ []) do
    with {:ok, url, _extract} <- registry(ecosystem, package),
         {:ok, body} <- fetch(url, opts) do
      case declared(ecosystem, body) do
        nil -> {:error, :unsupported}
        names -> {:ok, names}
      end
    end
  end

  # npm publishes every version; the dependencies wanted are the current one's.
  defp declared("npm", body) do
    latest = get_in(body, ["dist-tags", "latest"])
    version = get_in(body, ["versions", latest]) || %{}
    Map.keys(get_in(version, ["dependencies"]) || %{})
  end

  # hex answers with the latest release inline on the package document.
  defp declared("hex", body) do
    requirements =
      get_in(body, ["releases"]) |> List.wrap() |> List.first() |> Kernel.||(%{})

    case get_in(requirements, ["requirements"]) do
      %{} = reqs -> Map.keys(reqs)
      _ -> Map.keys(get_in(body, ["meta", "requirements"]) || %{})
    end
  end

  defp declared(_ecosystem, _body), do: nil

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
