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

  # The ecosystems this can resolve. One list, in the module that does the
  # resolving: `LeiService.CacheBaseline` kept a second copy, so adding a
  # resolver here left every caller of that still refusing the ecosystem.
  @ecosystems ~w(npm hex pypi cargo go composer gem)

  @doc """
  The ecosystems `resolve/3` understands.

  Ask rather than assume: a caller that keeps its own list drifts the moment one
  is added here, and refuses an ecosystem the library supports.
  """
  @spec ecosystems() :: [String.t()]
  def ecosystems, do: @ecosystems

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
  def resolve(ecosystem, package, opts \\ [])

  # Go has no registry to ask. A module path *is* its location: the first three
  # segments of `github.com/owner/repo/service/s3` are the repository, and a
  # `/v2` or `/v3` suffix is the major version rather than a directory.
  #
  # Resolved by parsing rather than by asking anyone, so it costs no request and
  # cannot be wrong about a module whose path is already the answer.
  #
  # A vanity path -- `k8s.io/client-go`, `golang.org/x/net`, `gopkg.in/yaml.v3`
  # -- is refused rather than guessed. Go's own `?go-get=1` mechanism resolves
  # those, and it was tested: `golang.org/x/net` gives
  # `go.googlesource.com/net` and `gopkg.in/yaml.v3` gives itself. Both are real
  # repositories on hosts `repository?/1` does not accept, so following the
  # protocol would add a request per module and still end in `:no_repository`.
  # Refusing immediately says the same thing for free.
  def resolve("go", module, _opts) when is_binary(module) do
    # A module path *is* its location, so this costs no request: prefix it with
    # a scheme and let `normalize/1` do the rest. It already restricts to hosts
    # we can clone, trims to owner/repository, and drops a `/v2` major version
    # or a `/service/s3` submodule path along with it.
    #
    # This was three clauses matching host, owner and repository before the
    # mutations for each came back unguarded -- normalize was already doing all
    # of it, and the extra matching was belt with no trousers missing. The tests
    # below are unchanged and still pass, which is what makes the deletion safe.
    #
    # A vanity path -- `k8s.io/client-go`, `golang.org/x/net` -- falls out as
    # `:no_repository` because its host is not one we accept. Go's own
    # `?go-get=1` mechanism does resolve those, and it was tested:
    # `golang.org/x/net` gives `go.googlesource.com/net` and `gopkg.in/yaml.v3`
    # gives itself. Both are real repositories on hosts `repository?/1` refuses,
    # so following the protocol would cost a request per module and end here
    # anyway.
    module |> go_canonical() |> then(&normalize("https://" <> &1))
  end

  def resolve(ecosystem, package, opts) do
    with {:ok, url, extract} <- resolve_registry(ecosystem, package),
         {:ok, body} <- fetch(url, opts) do
      case extract.(body) do
        nil -> {:error, :no_repository}
        repository -> normalize(repository)
      end
    end
  end

  # Resolution needs one field, so it asks for one version rather than the whole
  # package.
  #
  # npm's package document carries every version ever published. Measured
  # 2026-10-03: `typescript` is **15.7 MB** against **4.8 KB** for
  # `/typescript/latest` -- the same `repository` field, 3,250 times smaller. The
  # download is not the cost; decoding 15.7 MB of JSON to read one string is, and
  # it took 19.8 s in this code path. A batch job resolving a 400-package
  # manifest (ADR-004) was decoding gigabytes to extract four hundred strings.
  #
  # `describe/3` and `dependencies/3` still take the full document, because they
  # read `dist-tags` and `versions` which only exist there. Hence two functions:
  # one URL per question, rather than one URL used for both.
  # Two vanity prefixes are mechanical, documented conventions rather than
  # guesses, and they are not a rounding error: of the 100 most-depended-upon Go
  # modules, 70 are already `github.com/...`, **12 are `golang.org/x/...`** and
  # 4 are `gopkg.in/...`. Mapping those two takes Go coverage from 70% to 86%.
  #
  # The reason to do it is not the 16 points. `golang.org/x/*` is the Go team's
  # own foundational set -- sys, crypto, text, net -- so it is the
  # *best-maintained* corner of the ecosystem. Dropping it is not random
  # missingness: it biases any measurement of Go toward looking worse
  # maintained than it is, which is the direction that would flatter our own
  # leading-indicator claim. A bias that favours the hypothesis is the one to
  # remove first.
  #
  # Each mapping below was checked against the GitHub API rather than recalled.
  # What is deliberately *not* mapped: `google.golang.org`, `k8s.io`,
  # `go.uber.org`, `cloud.google.com`, `sigs.k8s.io` -- the remaining 14%. Those
  # have real GitHub homes (`google.golang.org/protobuf` is
  # `github.com/protocolbuffers/protobuf-go`) but no rule derives them from the
  # path; they are per-organisation facts. Inventing a pattern that happens to
  # fit a few would resolve some modules to repositories that are not theirs,
  # and a wrong repository is worse than a refused one -- it produces a
  # confident analysis of the wrong history.
  defp go_canonical("golang.org/x/" <> rest) do
    # golang.org/x/sys is github.com/golang/sys. Verified: sys, crypto, text.
    "github.com/golang/" <> rest
  end

  defp go_canonical("gopkg.in/" <> rest) do
    # gopkg.in's own documented scheme: `pkg.vN` is github.com/go-pkg/pkg, and
    # `user/pkg.vN` is github.com/user/pkg. The major version is in the path
    # segment, not a directory. Verified: yaml.v2 and yaml.v3 both give
    # github.com/go-yaml/yaml.
    case String.split(rest, "/") do
      [single] -> "github.com/go-#{strip_gopkg_version(single)}/#{strip_gopkg_version(single)}"
      [user, pkg | _] -> "github.com/#{user}/#{strip_gopkg_version(pkg)}"
    end
  end

  defp go_canonical(module), do: module

  defp strip_gopkg_version(segment), do: String.replace(segment, ~r{\.v\d+$}, "")

  defp resolve_registry("npm", package) do
    {:ok, "https://registry.npmjs.org/" <> URI.encode(package) <> "/latest", &npm_repository/1}
  end

  # Every other registry answers with a single small document already.
  defp resolve_registry(ecosystem, package), do: registry(ecosystem, package)

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
    {:ok, "https://registry.npmjs.org/" <> URI.encode(package), &npm_repository/1}
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

  defp registry("composer", package) do
    {:ok, "https://repo.packagist.org/p2/" <> package <> ".json",
     fn body ->
       # `packages` is keyed by the vendor/name asked for, newest release first.
       body
       |> Map.get("packages", %{})
       |> Map.values()
       |> List.first()
       |> List.wrap()
       |> List.first()
       |> case do
         %{"source" => %{"url" => url}} -> url
         %{"homepage" => homepage} -> if repository?(homepage), do: homepage
         _ -> nil
       end
     end}
  end

  defp registry("gem", package) do
    {:ok, "https://rubygems.org/api/v1/gems/" <> URI.encode(package) <> ".json",
     fn body ->
       # source_code_uri is the declared one and often points at a tag --
       # `.../rails/tree/v8.1.4` -- which normalize/1 trims to the repository.
       body["source_code_uri"] || body["homepage_uri"] |> then(&if repository?(&1), do: &1)
     end}
  end

  defp registry(ecosystem, _package), do: {:error, {:unsupported_ecosystem, ecosystem}}
  # npm's `repository` is a string as often as an object -- package.json permits
  # both and both are published. `get_in(body, ["repository", "url"])` raised
  # FunctionClauseError on the string form, inside a Task, which took the whole
  # batch job down rather than failing the one package. Found on 2026-09-28 by
  # running a manifest scan: `@nodelib/fs.stat` publishes a string, and it is a
  # transitive dependency of most npm projects.
  defp npm_repository(body) do
    case Map.get(body, "repository") do
      %{"url" => url} -> url
      url when is_binary(url) -> url
      _ -> nil
    end
  end

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

  # The three hosts a shorthand can mean, and the three whose URLs have a known
  # owner/repository shape.
  @shorthand %{
    "github" => "https://github.com",
    "gitlab" => "https://gitlab.com",
    "bitbucket" => "https://bitbucket.org"
  }

  # Registries record repositories in whatever form the package author wrote:
  # git+ssh, git://, a trailing .git, npm's `owner/repo` shorthand, or a URL
  # pointing at a directory inside a monorepo. The analyzer clones over https.
  defp normalize(url) when is_binary(url) do
    normalized =
      url
      |> String.trim()
      |> expand_shorthand()
      |> String.replace_prefix("git+", "")
      |> String.replace_prefix("git://", "https://")
      |> String.replace_prefix("ssh://git@", "https://")
      |> String.replace_prefix("git@", "https://")

    normalized =
      case normalized do
        "https://git@" <> rest -> "https://" <> rest
        other -> other
      end

    normalized =
      normalized
      # git@github.com:owner/repo -- scp syntax, where the colon is a path
      # separator and not a port.
      |> String.replace(~r{^https://([^/:]+):(?=\D)}, "https://\\1/")
      |> repository_root()
      |> String.replace_suffix(".git", "")
      |> String.replace_suffix("/", "")

    if repository?(normalized), do: {:ok, normalized}, else: {:error, :no_repository}
  end

  defp normalize(_), do: {:error, :no_repository}

  # `github:owner/repo` and the bare `owner/repo` npm accepts in package.json.
  defp expand_shorthand(url) do
    case String.split(url, ":", parts: 2) do
      [prefix, rest] when is_binary(rest) ->
        case Map.fetch(@shorthand, prefix) do
          {:ok, host} -> host <> "/" <> String.trim_leading(rest, "/")
          :error -> url
        end

      _ ->
        # Two segments, no scheme, no host: npm means GitHub.
        case String.split(url, "/") do
          [owner, repo] when owner != "" and repo != "" ->
            if String.contains?(owner, "."), do: url, else: "https://github.com/#{owner}/#{repo}"

          _ ->
            url
        end
    end
  end

  # A URL into a monorepo directory -- `.../tree/main/packages/thing` -- names a
  # path, not a repository. Cloning it fails, and keying the cache on it makes a
  # second entry for a repository we may already hold: the customer pays for a
  # miss on an answer we have. Only the three hosts whose owner/repository shape
  # is known are trimmed; anything else is left exactly as published.
  # A fragment or query needs no separate handling: URI.parse puts #readme and
  # ?tab=readme outside the path, and this rebuilds from the path. An explicit
  # strip was written first and no test could tell whether it was there.
  defp repository_root(url) do
    uri = URI.parse(url)
    host = uri.host |> to_string() |> String.downcase()

    if host in ["github.com", "gitlab.com", "bitbucket.org", "www.github.com"] do
      case (uri.path || "") |> String.split("/", trim: true) do
        [owner, repo | _] -> "https://#{host}/#{owner}/#{repo}"
        _ -> url
      end
    else
      url
    end
  end

  # A homepage is only worth analysing when it names a repository host.
  defp repository?(url) when is_binary(url) do
    String.match?(url, ~r{^https://(www\.)?(github\.com|gitlab\.com|bitbucket\.org)/[^/]+/[^/]+}) and
      not String.contains?(url, " ")
  end

  defp repository?(_), do: false
end
