defmodule Lei.Web.HTML do
  @moduledoc """
  HTML escaping for EEx templates rendered with `Lei.Web.HTMLEngine`.

  Every `<%= %>` is escaped unless the value is marked `{:safe, iodata}`. The
  templates were rendered with plain EEx, which escapes nothing, so an org or
  key name containing markup was written into the page verbatim.
  """

  @doc "Marks already-rendered HTML as safe to include without escaping."
  def safe(iodata), do: {:safe, iodata}

  @doc "The binary a `<%= %>` expression renders as."
  def to_html({:safe, iodata}), do: IO.iodata_to_binary(iodata)
  def to_html(nil), do: ""
  def to_html(list) when is_list(list), do: Enum.map_join(list, &to_html/1)
  def to_html(binary) when is_binary(binary), do: escape(binary)
  def to_html(other), do: other |> to_string() |> escape()

  @doc "Escapes the five characters that are significant in HTML text and attributes."
  def escape(binary) when is_binary(binary) do
    for <<c <- binary>>, into: "" do
      case c do
        ?& -> "&amp;"
        ?< -> "&lt;"
        ?> -> "&gt;"
        ?" -> "&quot;"
        ?' -> "&#39;"
        c -> <<c>>
      end
    end
  end
end

defmodule Lei.Web.HTMLEngine do
  @moduledoc """
  An EEx engine that HTML-escapes every `<%= %>` expression.

  Block expressions (`<%= if ... do %>`, `<%= for ... do %>`) produce template
  output rather than data, so their bodies come back marked safe: escaping
  them again would turn the page's own markup into text. Everything else --
  assigns, function results, database values -- is escaped. Supports `@name`
  assigns like `EEx.SmartEngine`.

  Render with `EEx.eval_file(path, [assigns: assigns], engine: Lei.Web.HTMLEngine)`:
  the engine goes in the options, the third argument, not the bindings.
  """
  @behaviour EEx.Engine

  @impl true
  defdelegate init(opts), to: EEx.Engine

  @impl true
  defdelegate handle_body(state), to: EEx.Engine

  @impl true
  defdelegate handle_begin(state), to: EEx.Engine

  @impl true
  defdelegate handle_text(state, meta, text), to: EEx.Engine

  @impl true
  def handle_end(quoted) do
    body = EEx.Engine.handle_end(quoted)
    quote do: {:safe, unquote(body)}
  end

  @impl true
  def handle_expr(state, "=", expr) do
    expr = Macro.prewalk(expr, &EEx.Engine.handle_assign/1)
    EEx.Engine.handle_expr(state, "=", quote(do: Lei.Web.HTML.to_html(unquote(expr))))
  end

  def handle_expr(state, marker, expr) do
    expr = Macro.prewalk(expr, &EEx.Engine.handle_assign/1)
    EEx.Engine.handle_expr(state, marker, expr)
  end
end
