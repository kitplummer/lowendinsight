# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Lei.Repo,
      {Oban, Application.fetch_env!(:lowendinsight, :oban)},
      Lei.BatchCache,
      {Plug.Cowboy,
       scheme: :http,
       plug: Lei.Web.Router,
       options: [port: Application.get_env(:lowendinsight, :web_port, 4000)]}
    ]

    opts = [strategy: :one_for_one, name: Lei.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
