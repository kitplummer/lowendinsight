defmodule Lei.Web.SessionAuth do
  @moduledoc """
  Plug that guards routes behind session authentication.
  Checks for `org_slug` in session, looks up the org, and assigns it.
  Redirects to /login if missing or invalid.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = Plug.Conn.fetch_session(conn)

    case get_session(conn, "org_slug") do
      nil ->
        redirect_to_login(conn)

      slug ->
        case Lei.ApiKeys.get_org_by_slug(slug) do
          nil ->
            conn
            |> clear_session()
            |> redirect_to_login()

          org ->
            assign(conn, :current_org, org)
        end
    end
  end

  defp redirect_to_login(conn) do
    conn
    |> put_resp_header("location", "/login")
    |> send_resp(302, "")
    |> halt()
  end
end
