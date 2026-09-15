defmodule Npm.RegistryTest do
  # The scanner asked replicate.npmjs.com, which answers 404 for every
  # package. It then analysed the bare package name instead of the
  # repository, and the scan tests still passed: they count reports, and a
  # failed lookup still produces one.
  use ExUnit.Case, async: true

  defp registry(status, body) do
    test_pid = self()

    fn url ->
      send(test_pid, {:requested, url})
      {:ok, %HTTPoison.Response{status_code: status, body: body}}
    end
  end

  test "looks the package up in the npm registry and returns its repository url" do
    body =
      ~s({"name":"left-pad","repository":{"type":"git","url":"git+https://github.com/stevemao/left-pad.git"}})

    assert Npm.Scanner.repository_url("left-pad", registry(200, body)) ==
             {:ok, "git+https://github.com/stevemao/left-pad.git"}

    assert_received {:requested, "https://registry.npmjs.org/left-pad"}
  end

  test "a scoped package keeps its scope in the registry path" do
    Npm.Scanner.repository_url("@babel/core", registry(404, ""))
    assert_received {:requested, "https://registry.npmjs.org/@babel/core"}
  end

  test "a package the registry does not know has no repository" do
    assert Npm.Scanner.repository_url("no-such-package", registry(404, ~s({"error":"Not found"}))) ==
             :none
  end

  test "a package without a repository field has no repository" do
    assert Npm.Scanner.repository_url("x", registry(200, ~s({"name":"x"}))) == :none
  end

  test "a transport error has no repository rather than raising" do
    get = fn _ -> {:error, %HTTPoison.Error{reason: :econnrefused}} end
    assert Npm.Scanner.repository_url("x", get) == :none
  end

  @tag :network
  test "the live registry returns a repository for a real package" do
    assert {:ok, url} = Npm.Scanner.repository_url("left-pad")
    assert url =~ "github.com/stevemao/left-pad"
  end
end
