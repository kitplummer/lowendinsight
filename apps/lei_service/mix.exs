# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LeiService.MixProject do
  use Mix.Project

  def project do
    [
      app: :lei_service,
      version: "0.9.4",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: deps(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :sasl, :runtime_tools],
      mod: {LeiService.Application, []}
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.15"},
      {:joken, "~> 2.7"},
      {:elixir_uuid, "~> 1.2"},
      # Called directly (Stripe, Tempo RPC, GitHub); declared rather than
      # inherited from the library.
      {:httpoison, "~> 3.0"},
      {:cowboy, "~> 2.9", override: true},
      {:plug_cowboy, "~> 2.7"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:redix, ">= 0.0.0"},
      {:oban, "~> 2.24"},
      {:ecto_sql, "~> 3.11"},
      {:jason, "~> 1.4"},
      {:postgrex, "~> 0.18"},
      {:lowendinsight, in_umbrella: true},
      {:excoveralls, "~> 0.18", only: :test},
      {:mox, "~> 1.1", only: :test}
    ]
  end
end
