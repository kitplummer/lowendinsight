defmodule Lei.Application do
  @moduledoc """
  OTP Application for LEI batch analysis service.

  Starts the ETS-backed batch cache and optional HTTP endpoint.
  """
  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:lowendinsight, :http_port, 4000)

    base = [Lei.Repo, Lei.BatchCache]

    children =
      if Application.get_env(:lowendinsight, :start_http, false) do
        base ++ [{Plug.Cowboy, scheme: :http, plug: Lei.Web.Router, options: [port: port]}]
      else
        base
      end

    opts = [strategy: :one_for_one, name: Lei.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
