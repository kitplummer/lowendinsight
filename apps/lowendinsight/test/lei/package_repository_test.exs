defmodule Lei.PackageRepositoryTest do
  @moduledoc """
  A package coordinate resolves to the repository to analyse.

  A batch request names packages (ecosystem, package, version); an analysis
  needs a repository URL. The scanners each knew how to find one, buried in a
  function that immediately analysed it, so nothing else could ask.
  """
  use ExUnit.Case, async: true

  alias Lei.PackageRepository

  defp responder(status, body) do
    test_pid = self()

    fn url ->
      send(test_pid, {:requested, url})
      {:ok, %HTTPoison.Response{status_code: status, body: body}}
    end
  end

  test "npm: the registry's repository url" do
    body = ~s({"repository":{"type":"git","url":"git+https://github.com/o/r.git"}})

    assert PackageRepository.resolve("npm", "left-pad", get: responder(200, body)) ==
             {:ok, "https://github.com/o/r"}

    # /latest, not the full package document: see "resolution asks for one
    # version" below for why, and what it measured.
    assert_received {:requested, "https://registry.npmjs.org/left-pad/latest"}
  end

  test "hex: the package's GitHub link, whatever its case" do
    body = ~s({"meta":{"links":{"GitHub":"https://github.com/o/r"}}})

    assert PackageRepository.resolve("hex", "jason", get: responder(200, body)) ==
             {:ok, "https://github.com/o/r"}

    assert_received {:requested, "https://hex.pm/api/packages/jason"}

    lower = ~s({"meta":{"links":{"github":"https://github.com/o/r"}}})

    assert PackageRepository.resolve("hex", "jason", get: responder(200, lower)) ==
             {:ok, "https://github.com/o/r"}
  end

  test "pypi: the source url, preferred over the homepage" do
    body =
      ~s({"info":{"project_urls":{"Homepage":"https://example.com","Source":"https://github.com/o/r"}}})

    assert PackageRepository.resolve("pypi", "requests", get: responder(200, body)) ==
             {:ok, "https://github.com/o/r"}

    assert_received {:requested, "https://pypi.org/pypi/requests/json"}
  end

  test "pypi: falls back to the homepage when it is a repository" do
    body = ~s({"info":{"project_urls":{"Homepage":"https://github.com/o/r"}}})

    assert PackageRepository.resolve("pypi", "x", get: responder(200, body)) ==
             {:ok, "https://github.com/o/r"}
  end

  test "pypi: a homepage that is not a repository does not resolve" do
    body = ~s({"info":{"project_urls":{"Homepage":"https://example.com/docs"}}})

    assert PackageRepository.resolve("pypi", "x", get: responder(200, body)) ==
             {:error, :no_repository}
  end

  test "cargo: the crate's repository" do
    body = ~s({"crate":{"repository":"https://github.com/o/r"}})

    assert PackageRepository.resolve("cargo", "serde", get: responder(200, body)) ==
             {:ok, "https://github.com/o/r"}

    assert_received {:requested, "https://crates.io/api/v1/crates/serde"}
  end

  test "an unknown ecosystem is refused, not guessed" do
    assert PackageRepository.resolve("cocoapods", "x", get: responder(200, "{}")) ==
             {:error, {:unsupported_ecosystem, "cocoapods"}}

    refute_received {:requested, _}
  end

  test "a registry that is down fails the job quickly rather than holding a worker" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    get = fn _ ->
      Agent.update(agent, &(&1 + 1)) && {:error, %HTTPoison.Error{reason: :timeout}}
    end

    {elapsed_us, result} =
      :timer.tc(fn -> PackageRepository.resolve("npm", "x", get: get, retry: [wait: 1]) end)

    assert result == {:error, {:unreachable, :timeout}}
    assert Agent.get(agent, & &1) == 3, "the default retry budget is 3 attempts"
    assert elapsed_us < 5_000_000
  end

  test "a package the registry does not know does not resolve" do
    assert PackageRepository.resolve("npm", "nope", get: responder(404, "")) ==
             {:error, :not_found}
  end

  test "a registry that cannot be reached is an error, not a missing repository" do
    get = fn _ -> {:error, %HTTPoison.Error{reason: :nxdomain}} end

    assert PackageRepository.resolve("npm", "x", get: get, retry: [max_attempts: 2, wait: 1]) ==
             {:error, {:unreachable, :nxdomain}}
  end

  test "a package with no repository field does not resolve" do
    assert PackageRepository.resolve("npm", "x", get: responder(200, ~s({"name":"x"}))) ==
             {:error, :no_repository}
  end

  test "git+ssh and .git urls become https urls the analyzer can clone" do
    for {given, want} <- [
          {"git+https://github.com/o/r.git", "https://github.com/o/r"},
          {"git+ssh://git@github.com/o/r.git", "https://github.com/o/r"},
          {"git://github.com/o/r.git", "https://github.com/o/r"},
          {"https://github.com/o/r", "https://github.com/o/r"}
        ] do
      body = ~s({"repository":{"url":"#{given}"}})
      assert PackageRepository.resolve("npm", "x", get: responder(200, body)) == {:ok, want}
    end
  end

  describe "resolution asks for one version, not the whole package" do
    test "npm resolution requests /latest" do
      # npm's package document carries every version ever published. Measured
      # 2026-10-03: typescript is 15.7 MB against 4.8 KB for /typescript/latest,
      # the same repository field 3,250 times smaller. The download is not the
      # cost; decoding 15.7 MB to read one string is, and it took 19.8 s here. A
      # batch job resolving a 400-package manifest was decoding gigabytes to
      # extract four hundred strings.
      body = ~s({"repository":{"url":"git+https://github.com/o/r.git"}})

      assert PackageRepository.resolve("npm", "typescript", get: responder(200, body)) ==
               {:ok, "https://github.com/o/r"}

      assert_received {:requested, "https://registry.npmjs.org/typescript/latest"}
    end

    test "dependencies still read the full document" do
      # dist-tags and versions exist only there, so describe/3 and
      # dependencies/3 must not be moved onto the light endpoint with it.
      body =
        ~s({"dist-tags":{"latest":"1.0.0"},"versions":{"1.0.0":{"dependencies":{"left-pad":"^1"}}}})

      assert PackageRepository.dependencies("npm", "express", get: responder(200, body)) ==
               {:ok, ["left-pad"]}

      assert_received {:requested, "https://registry.npmjs.org/express"}
    end

    test "a registry whose document is already small is unchanged" do
      body = ~s({"meta":{"links":{"GitHub":"https://github.com/o/r"}}})

      assert PackageRepository.resolve("hex", "jason", get: responder(200, body)) ==
               {:ok, "https://github.com/o/r"}

      assert_received {:requested, "https://hex.pm/api/packages/jason"}
    end
  end

  describe "the forms npm actually publishes" do
    # All four found on 2026-09-28 by resolving 16,000 real coordinates from
    # fifty public manifests. Reasoning from the registry documentation would
    # have produced none of them.

    test "a string repository resolves instead of raising" do
      # `get_in(body, ["repository", "url"])` on a string raised
      # FunctionClauseError inside a Task, which took the whole batch job down
      # rather than failing this one package. @nodelib/fs.stat publishes this
      # form and is a transitive dependency of most npm projects, so a manifest
      # scan hit it immediately.
      body = ~s({"repository":"https://github.com/o/r"})

      assert PackageRepository.resolve("npm", "x", get: responder(200, body)) ==
               {:ok, "https://github.com/o/r"}
    end

    test "a url into a monorepo directory resolves to the repository" do
      # A path is not a clone target. It also makes a second cache key for a
      # repository we may already hold, so the customer pays for a miss on an
      # answer we have.
      body =
        ~s({"repository":"https://github.com/nodelib/nodelib/tree/master/packages/fs/fs.stat"})

      assert PackageRepository.resolve("npm", "x", get: responder(200, body)) ==
               {:ok, "https://github.com/nodelib/nodelib"}
    end

    test "the shorthand forms package.json permits resolve" do
      for {given, want} <- [
            {"github:o/r", "https://github.com/o/r"},
            {"gitlab:o/r", "https://gitlab.com/o/r"},
            {"bitbucket:o/r", "https://bitbucket.org/o/r"},
            {"o/r", "https://github.com/o/r"},
            {"git@github.com:o/r.git", "https://github.com/o/r"}
          ] do
        body = ~s({"repository":{"url":"#{given}"}})

        assert PackageRepository.resolve("npm", "x", get: responder(200, body)) == {:ok, want},
               "#{given} did not resolve to #{want}"
      end
    end

    test "a fragment or query is dropped" do
      body = ~s({"repository":"https://github.com/o/r#readme"})

      assert PackageRepository.resolve("npm", "x", get: responder(200, body)) ==
               {:ok, "https://github.com/o/r"}
    end

    test "a repository field of some other shape still does not resolve" do
      # Not "anything non-nil is a URL": a number or a list must fail cleanly,
      # the same as a missing field.
      for body <- [~s({"repository":42}), ~s({"repository":[]}), ~s({"repository":{}})] do
        assert PackageRepository.resolve("npm", "x", get: responder(200, body)) ==
                 {:error, :no_repository}
      end
    end
  end

  describe "pypi project_urls, which authors write however they like" do
    test "a source key is found whatever its case" do
      # PyPI does not normalise these keys. Looking for "Source" exactly dropped
      # numpy, pandas, scipy and tqdm -- 10 of the 50 most-depended-upon PyPI
      # packages -- and reported `:no_repository`, which reads as "the package
      # declares no repository" rather than "we did not look properly".
      for key <- ["source", "Source", "SOURCE", "Source Code", "source-code", "source_code"] do
        body = ~s({"info":{"project_urls":{"#{key}":"https://github.com/numpy/numpy"}}})

        assert PackageRepository.resolve("pypi", "numpy", get: responder(200, body)) ==
                 {:ok, "https://github.com/numpy/numpy"},
               "the key #{inspect(key)} was not matched"
      end
    end

    test "repository, repo and github are source keys too" do
      # pandas and tqdm both use `repository`.
      for key <- ["repository", "Repository", "repo", "github", "GitHub", "git"] do
        body = ~s({"info":{"project_urls":{"#{key}":"https://github.com/o/p"}}})

        assert PackageRepository.resolve("pypi", "p", get: responder(200, body)) ==
                 {:ok, "https://github.com/o/p"},
               "the key #{inspect(key)} was not matched"
      end
    end

    test "the plural Sources is matched" do
      # pytest-cov uses it, and no amount of case folding would have found it.
      body = ~s({"info":{"project_urls":{"Sources":"https://github.com/pytest-dev/pytest-cov"}}})

      assert PackageRepository.resolve("pypi", "pytest-cov", get: responder(200, body)) ==
               {:ok, "https://github.com/pytest-dev/pytest-cov"}
    end

    test "a homepage is accepted in any case, but only when it is a repository" do
      for key <- ["Homepage", "homepage", "home_page"] do
        body = ~s({"info":{"project_urls":{"#{key}":"https://github.com/o/p"}}})

        assert PackageRepository.resolve("pypi", "p", get: responder(200, body)) ==
                 {:ok, "https://github.com/o/p"},
               "the key #{inspect(key)} was not matched"
      end

      # odoo declares only a homepage, and it is not somewhere to clone. It
      # must stay refused: this fix widens the lookup, not what counts as a
      # repository.
      body = ~s({"info":{"project_urls":{"Homepage":"https://www.odoo.com"}}})

      assert PackageRepository.resolve("pypi", "odoo", get: responder(200, body)) ==
               {:error, :no_repository}
    end

    test "a documentation or tracker url is not mistaken for the source" do
      # A wrong repository is worse than a refused one -- it produces a
      # confident analysis of the wrong history. Only source-like keys count,
      # so a package whose docs happen to live on someone else's GitHub is not
      # resolved to that someone else.
      body =
        ~s({"info":{"project_urls":{"Documentation":"https://github.com/sphinx-doc/sphinx","Changelog":"https://example.com/c"}}})

      assert PackageRepository.resolve("pypi", "p", get: responder(200, body)) ==
               {:error, :no_repository}
    end

    test "no project_urls at all is refused, not crashed on" do
      assert PackageRepository.resolve("pypi", "p", get: responder(200, ~s({"info":{}}))) ==
               {:error, :no_repository}
    end
  end

  describe "go, which has no registry to ask" do
    test "a module path is its own location" do
      # No request at all: the first three segments of a module path are the
      # repository. A resolver that asked someone would be slower and no more
      # correct.
      assert PackageRepository.resolve("go", "github.com/gin-gonic/gin") ==
               {:ok, "https://github.com/gin-gonic/gin"}

      refute_received {:requested, _}
    end

    test "a submodule path resolves to the repository that contains it" do
      # The repository is aws-sdk-go-v2; service/s3 is a directory in it. Taking
      # the whole path would produce a clone target that does not exist.
      assert PackageRepository.resolve("go", "github.com/aws/aws-sdk-go-v2/service/s3") ==
               {:ok, "https://github.com/aws/aws-sdk-go-v2"}
    end

    test "a major version suffix belongs to the module, not the repository" do
      assert PackageRepository.resolve("go", "github.com/stretchr/testify/v2") ==
               {:ok, "https://github.com/stretchr/testify"}
    end

    test "gitlab and bitbucket module paths resolve too" do
      assert PackageRepository.resolve("go", "gitlab.com/o/r") ==
               {:ok, "https://gitlab.com/o/r"}

      assert PackageRepository.resolve("go", "bitbucket.org/o/r") ==
               {:ok, "https://bitbucket.org/o/r"}
    end

    test "golang.org/x maps to the go team's github mirror" do
      # Of the 100 most-depended-upon Go modules, 12 are golang.org/x. They are
      # also the Go team's own foundational set, so dropping them does not
      # thin the sample evenly -- it removes the best-maintained corner of the
      # ecosystem and biases any measurement of Go toward looking worse than it
      # is. That is the direction that would flatter our own claim.
      #
      # Each target was checked against the GitHub API, not recalled.
      assert PackageRepository.resolve("go", "golang.org/x/sys") ==
               {:ok, "https://github.com/golang/sys"}

      assert PackageRepository.resolve("go", "golang.org/x/crypto") ==
               {:ok, "https://github.com/golang/crypto"}

      assert PackageRepository.resolve("go", "golang.org/x/net") ==
               {:ok, "https://github.com/golang/net"}
    end

    test "gopkg.in follows its own documented scheme" do
      # `pkg.vN` is github.com/go-pkg/pkg; `user/pkg.vN` is github.com/user/pkg.
      # The major version lives in the path segment rather than a directory, so
      # v2 and v3 of yaml are one repository.
      assert PackageRepository.resolve("go", "gopkg.in/yaml.v3") ==
               {:ok, "https://github.com/go-yaml/yaml"}

      assert PackageRepository.resolve("go", "gopkg.in/yaml.v2") ==
               {:ok, "https://github.com/go-yaml/yaml"}

      assert PackageRepository.resolve("go", "gopkg.in/check.v1") ==
               {:ok, "https://github.com/go-check/check"}
    end

    test "a vanity prefix with no mechanical rule stays refused" do
      # The remaining 14% of the top 100: google.golang.org, k8s.io,
      # go.uber.org, cloud.google.com, sigs.k8s.io. Each has a real GitHub home
      # -- google.golang.org/protobuf is github.com/protocolbuffers/protobuf-go
      # -- but no rule derives it from the path. Inventing a pattern that fits a
      # few would resolve some modules to repositories that are not theirs, and
      # a confident analysis of the wrong history is worse than a refusal.
      assert PackageRepository.resolve("go", "google.golang.org/protobuf") ==
               {:error, :no_repository}

      assert PackageRepository.resolve("go", "k8s.io/client-go") == {:error, :no_repository}
      assert PackageRepository.resolve("go", "go.uber.org/zap") == {:error, :no_repository}
    end

    test "a vanity path is refused rather than guessed" do
      # `k8s.io/client-go` is a real module whose repository is
      # github.com/kubernetes/client-go, and nothing in the path says so.
      # Go's own ?go-get=1 mechanism answers these, and was tested -- but it
      # answers with the *canonical* repository, which for golang.org/x/net is
      # go.googlesource.com/net, a host `repository?/1` does not accept. The
      # mapping above reaches the GitHub mirror of the same history instead,
      # which is why the convention is used for the two prefixes that have one
      # and the protocol is not used at all.
      assert PackageRepository.resolve("go", "k8s.io/client-go") == {:error, :no_repository}
      assert PackageRepository.resolve("go", "example.com/thing") == {:error, :no_repository}
    end

    test "a path too short to name a repository is refused" do
      assert PackageRepository.resolve("go", "github.com/owner") == {:error, :no_repository}
      assert PackageRepository.resolve("go", "github.com") == {:error, :no_repository}
    end
  end

  describe "composer and rubygems" do
    test "composer reads the declared source" do
      body =
        ~s({"packages":{"symfony/console":[{"source":{"url":"https://github.com/symfony/console.git","type":"git"}}]}})

      assert PackageRepository.resolve("composer", "symfony/console", get: responder(200, body)) ==
               {:ok, "https://github.com/symfony/console"}

      assert_received {:requested, "https://repo.packagist.org/p2/symfony/console.json"}
    end

    test "composer falls back to a homepage that is a repository" do
      body = ~s({"packages":{"o/p":[{"homepage":"https://github.com/o/p"}]}})

      assert PackageRepository.resolve("composer", "o/p", get: responder(200, body)) ==
               {:ok, "https://github.com/o/p"}
    end

    test "composer does not accept a homepage that is not a repository" do
      body = ~s({"packages":{"o/p":[{"homepage":"https://example.com/p"}]}})

      assert PackageRepository.resolve("composer", "o/p", get: responder(200, body)) ==
               {:error, :no_repository}
    end

    test "rubygems reads source_code_uri, trimmed to the repository" do
      # RubyGems commonly declares a tag: rails gives
      # https://github.com/rails/rails/tree/v8.1.4, which is a path rather than
      # a clone target.
      body = ~s({"source_code_uri":"https://github.com/rails/rails/tree/v8.1.4"})

      assert PackageRepository.resolve("gem", "rails", get: responder(200, body)) ==
               {:ok, "https://github.com/rails/rails"}

      assert_received {:requested, "https://rubygems.org/api/v1/gems/rails.json"}
    end

    test "rubygems falls back to a homepage that is a repository" do
      body = ~s({"source_code_uri":null,"homepage_uri":"https://github.com/o/g"})

      assert PackageRepository.resolve("gem", "g", get: responder(200, body)) ==
               {:ok, "https://github.com/o/g"}
    end

    test "rubygems does not accept a homepage that is not a repository" do
      # rails' homepage is rubyonrails.org, which is not somewhere to clone.
      body = ~s({"source_code_uri":null,"homepage_uri":"https://rubyonrails.org"})

      assert PackageRepository.resolve("gem", "g", get: responder(200, body)) ==
               {:error, :no_repository}
    end
  end

  @tag :network
  test "the live registries resolve a real package in each ecosystem" do
    assert {:ok, npm} = PackageRepository.resolve("npm", "left-pad")
    assert npm =~ "github.com/stevemao/left-pad"

    assert {:ok, hex} = PackageRepository.resolve("hex", "jason")
    assert hex =~ "github.com"

    assert {:ok, pypi} = PackageRepository.resolve("pypi", "requests")
    assert pypi =~ "github.com"

    assert {:ok, cargo} = PackageRepository.resolve("cargo", "serde")
    assert cargo =~ "github.com"
  end
end
