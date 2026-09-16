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

    assert_received {:requested, "https://registry.npmjs.org/left-pad"}
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
