# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Application do
  @moduledoc """
  OTP Application for LowEndInsight.

  Starts the supervision tree including the HTTP endpoint,
  batch analysis job registry, and task supervisor.
  """

  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:lowendinsight, :http_port, 4000)

    children = [
      {Task.Supervisor, name: Lei.TaskSupervisor},
      Lei.Registry,
      {Plug.Cowboy, scheme: :http, plug: Lei.Web.Router, options: [port: port]}
    ]

    opts = [strategy: :one_for_one, name: Lei.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
