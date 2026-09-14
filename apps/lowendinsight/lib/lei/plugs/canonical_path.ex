defmodule Lei.Plugs.CanonicalPath do
  @moduledoc """
  Makes `request_path` the path the router will actually match.

  Plug.Router percent-decodes each segment of `path_info` before matching, but
  `request_path` is left as the client sent it. Every check that decides on the
  path -- both auth plugs, the rate limiter, the payment gate, the forwarding
  table -- read `request_path`. So `GET /%761/cache/stats` was matched as
  /v1/cache/stats by the router while the auth plug saw no "/v1" and waved it
  through, unauthenticated, in production.

  Rather than teach each of those checks to decode, this runs first and
  rewrites `request_path` once, so everything downstream sees one path. A
  segment that decodes to text containing "/" (the Try It form's
  `/url=https%3A%2F%2F...`) is joined as-is: a check that over-matches on it
  fails closed, and the router still sees the original single segment.

  Decoding uses the same function the router does (`URI.decode/1`, via
  `Plug.Router.Utils.decode_path_info!/1`), so the two cannot disagree -- a
  malformed escape such as `%zz` is left as-is by both.
  """

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: segments} = conn, _opts) do
    %{conn | request_path: "/" <> Enum.map_join(segments, "/", &URI.decode/1)}
  end
end
