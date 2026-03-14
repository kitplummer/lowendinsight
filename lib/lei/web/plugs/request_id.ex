defmodule Lei.Web.Plugs.RequestId do
  @moduledoc """
  Assigns a UUID request ID to each request, stores it in Logger metadata,
  and returns it in the X-Request-ID response header.

  If the client supplies a valid UUID in the X-Request-ID request header,
  that value is used; otherwise a new UUID is generated.
  """

  @behaviour Plug
  require Logger

  @header "x-request-id"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    request_id = get_or_generate(conn)
    Logger.metadata(request_id: request_id)

    conn
    |> Plug.Conn.put_resp_header(@header, request_id)
  end

  defp get_or_generate(conn) do
    case Plug.Conn.get_req_header(conn, @header) do
      [id | _] when byte_size(id) > 0 ->
        case Ecto.UUID.cast(id) do
          {:ok, _} -> id
          :error -> Ecto.UUID.generate()
        end

      _ ->
        Ecto.UUID.generate()
    end
  end
end
