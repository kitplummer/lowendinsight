defmodule Lowendinsight.DeclaredDependenciesTest do
  # Inside the umbrella every app shares one deps directory, so the library
  # compiled and passed its tests while calling Jason, which only the service
  # declared. A project depending on the library from Hex would not have had
  # it (ADR-003). scripts/library-isolation.sh proves the same thing from
  # outside; this catches it in the suite.
  use ExUnit.Case, async: true

  @service_apps ~w(ecto ecto_sql postgrex plug plug_cowboy cowboy joken exqlite oban redix)a

  test "every module the library calls belongs to OTP, Elixir or a declared dependency" do
    {:ok, modules} = :application.get_key(:lowendinsight, :modules)
    assert length(modules) > 20, "no library modules found; this test would check nothing"

    declared = MapSet.new(Application.spec(:lowendinsight, :applications))

    undeclared =
      for mod <- modules,
          {:ok, {_, [imports: imports]}} = :beam_lib.chunks(:code.which(mod), [:imports]),
          {callee, _fun, _arity} <- imports,
          app = owning_app(callee),
          app not in [nil, :lowendinsight],
          not platform_app?(app),
          not MapSet.member?(declared, app),
          uniq: true,
          do: {app, callee, mod}

    assert undeclared == [],
           "the library calls modules from applications it does not depend on:\n" <>
             Enum.map_join(undeclared, "\n", fn {app, callee, mod} ->
               "  #{inspect(mod)} -> #{inspect(callee)} (#{app})"
             end)
  end

  test "the compiled application list matches mix.exs, so a stale build fails here" do
    # Application.spec/2 reads the compiled .app. If mix.exs changed and the
    # app was not rebuilt -- which happens when an earlier step of a run
    # failed -- the test above compares against the old dependency list and
    # passes while the bug it guards is present. Comparing the two sources
    # makes that state a failure.
    declared =
      Mix.Project.config()[:deps]
      |> Enum.map(fn
        {name, req} when is_binary(req) -> {name, []}
        {name, opts} when is_list(opts) -> {name, opts}
        {name, _req, opts} -> {name, opts}
      end)
      # A dep with `only:` is started in the environments it names, and this
      # runs in :test, so it counts there.
      |> Enum.reject(fn {_name, opts} ->
        only = opts |> Keyword.get(:only, Mix.env()) |> List.wrap()
        Keyword.get(opts, :runtime) == false or Mix.env() not in only
      end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    started = MapSet.new(Application.spec(:lowendinsight, :applications))

    assert MapSet.size(declared) > 0, "no runtime dependencies read from mix.exs"

    stale = MapSet.difference(MapSet.intersection(started, known_dep_names()), declared)

    assert MapSet.equal?(stale, MapSet.new()),
           "the compiled application list has #{inspect(MapSet.to_list(stale))}, " <>
             "which mix.exs no longer declares: the build is stale, so the checks " <>
             "above are comparing against an old dependency list"

    missing = MapSet.difference(declared, started)

    assert MapSet.equal?(missing, MapSet.new()),
           "mix.exs declares #{inspect(MapSet.to_list(missing))} but the compiled " <>
             "application does not start them"
  end

  # Every dependency name Mix knows about, so the comparison above ignores OTP
  # and Elixir applications listed through extra_applications.
  defp known_dep_names do
    Mix.Dep.cached()
    |> Enum.map(& &1.app)
    |> MapSet.new()
  end

  test "the library does not start any service application" do
    applications = Application.spec(:lowendinsight, :applications)
    assert applications != []
    assert Enum.filter(applications, &(&1 in @service_apps)) == []
  end

  defp owning_app(module) do
    case :application.get_application(module) do
      {:ok, app} -> app
      :undefined -> nil
    end
  end

  # OTP ships under the Erlang root; Elixir's own applications sit beside elixir.
  defp platform_app?(app) do
    dir = to_string(:code.lib_dir(app))

    String.starts_with?(dir, to_string(:code.root_dir())) or
      Path.dirname(dir) == Path.dirname(to_string(:code.lib_dir(:elixir)))
  end
end
