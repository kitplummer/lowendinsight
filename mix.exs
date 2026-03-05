# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lowendinsight.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.9.1",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      releases: [
        lowendinsight_get: [
          applications: [
            lowendinsight: :permanent,
            lowendinsight_get: :permanent,
            runtime_tools: :permanent
          ]
        ]
      ]
    ]
  end

  defp deps do
    []
  end

  defp aliases do
    [
      "test.lei": &test_lei/1,
      "test.get": &test_get/1,
      "ecto.setup": &ecto_setup/1,
      "ecto.reset": &ecto_reset/1
    ]
  end

  defp test_lei(args), do: run_in_app("lowendinsight", "mix test #{Enum.join(args, " ")}")
  defp test_get(args), do: run_in_app("lowendinsight_get", "mix test #{Enum.join(args, " ")}")
  defp ecto_setup(_), do: run_in_app("lowendinsight_get", "mix do ecto.create, ecto.migrate")

  defp ecto_reset(_),
    do: run_in_app("lowendinsight_get", "mix do ecto.drop, ecto.create, ecto.migrate")

  defp run_in_app(app, command) do
    {_, status} = System.shell(command, cd: Path.join("apps", app), into: IO.stream())
    if status != 0, do: System.at_exit(fn _ -> exit({:shutdown, status}) end)
  end
end
