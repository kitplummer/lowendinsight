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
