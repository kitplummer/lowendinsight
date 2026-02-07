defmodule Lei.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Lei.Repo,
      {Oban, Application.fetch_env!(:lowendinsight, :oban)},
      Lei.Cache,
      {Plug.Cowboy,
       scheme: :http,
       plug: Lei.Web.Router,
       options: [port: Application.get_env(:lowendinsight, :web_port, 4000)]}
    ]

    opts = [strategy: :one_for_one, name: Lei.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
