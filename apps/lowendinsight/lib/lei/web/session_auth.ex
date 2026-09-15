defmodule Lei.Web.SessionAuth do
  @moduledoc """
  Plug that guards routes behind session authentication.

  A session names the admin key it was opened with and when. It is accepted
  only while that key is still active, still has admin scope, still belongs to
  the org, the org is active, and the session is younger than
  `max_age_seconds/0`.

  It used to hold only the org slug. The cookie is signed, not stored, so
  logging out or revoking the key ended nothing: a copied cookie opened the
  dashboard -- and its key management -- indefinitely.
  """
  import Plug.Conn

  @max_age_seconds 12 * 60 * 60

  def max_age_seconds, do: @max_age_seconds

  def init(opts), do: opts

  @doc "Opens a session for an authenticated admin key."
  def sign_in(conn, %Lei.ApiKey{} = api_key) do
    conn
    |> fetch_session()
    |> configure_session(renew: true)
    |> put_session("org_slug", api_key.org.slug)
    |> put_session("api_key_id", api_key.id)
    |> put_session("signed_in_at", System.system_time(:second))
  end

  def call(conn, _opts) do
    conn = fetch_session(conn)

    with slug when is_binary(slug) <- get_session(conn, "org_slug"),
         key_id when is_integer(key_id) <- get_session(conn, "api_key_id"),
         at when is_integer(at) <- get_session(conn, "signed_in_at"),
         true <- System.system_time(:second) - at < @max_age_seconds,
         %Lei.ApiKey{active: true, org: %Lei.Org{slug: ^slug, status: "active"} = org} = key <-
           Lei.Repo.get(Lei.ApiKey, key_id) |> Lei.Repo.preload(:org),
         true <- "admin" in key.scopes do
      assign(conn, :current_org, org)
    else
      _ ->
        conn
        |> clear_session()
        |> redirect_to_login()
    end
  end

  defp redirect_to_login(conn) do
    conn
    |> put_resp_header("location", "/login")
    |> send_resp(302, "")
    |> halt()
  end
end
