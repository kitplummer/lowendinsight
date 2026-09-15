defmodule LeiService.ReportView do
  @moduledoc """
  Formatting for the report detail page (analysis.html.eex).

  Everything here returns plain values; the template renders them through
  Lei.Web.HTMLEngine, which escapes them. Repository owners control much of a
  report -- contributor names, branch names -- so nothing here marks text safe.
  """

  @doc "The report as a string-keyed map, from the JSON the analysis produced."
  def decode(report) when is_binary(report), do: Poison.decode!(report)
  def decode(%{} = report), do: report |> Poison.encode!() |> Poison.decode!()

  @doc "A link target for the repository, or nil unless it is http or https."
  def project_href(url) when is_binary(url) do
    if String.match?(url, ~r/\Ahttps?:\/\//i), do: url, else: nil
  end

  def project_href(_), do: nil

  @doc "The CSS class for a risk level, and a neutral one for anything else."
  def risk_class(level) when level in ["critical", "high", "medium", "low"], do: "risk-#{level}"
  def risk_class(_), do: "risk-none"

  @doc "A risk level for display."
  def risk_label(level) when is_binary(level) and level != "", do: String.capitalize(level)
  def risk_label(_), do: "Not scored"

  @doc "A value for display, with a placeholder for missing ones."
  def show(nil), do: "—"
  def show(""), do: "—"
  def show(true), do: "Yes"
  def show(false), do: "No"
  def show(value), do: to_string(value)

  @doc "A fraction of the codebase as a percentage."
  def percent(value) when is_number(value),
    do: :erlang.float_to_binary(value * 100.0, decimals: 2) <> "%"

  def percent(_), do: "—"

  @doc "A ratio (0..1) as a whole percentage."
  def ratio(value) when is_number(value), do: "#{round(value * 100)}%"
  def ratio(_), do: "—"

  @doc "A date or datetime as YYYY-MM-DD, or the original text if it is not one."
  def date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> Date.to_iso8601(DateTime.to_date(dt))
      _ -> String.slice(value, 0, 10)
    end
  end

  def date(_), do: "—"

  @doc "The default branch without git's remote-tracking prefix."
  def branch(value) when is_binary(value) do
    value
    |> String.replace_prefix("refs/remotes/origin/", "")
    |> String.replace_prefix("refs/heads/", "")
  end

  def branch(value), do: show(value)

  @doc """
  `repo_size`, which is `git count-objects`' loose-object size in kilobytes.
  After a clone almost everything is packed, so it is usually small or zero;
  labelled for what it is rather than as the repository's size.
  """
  def loose_objects(kb) when is_integer(kb), do: "#{kb} KB"

  def loose_objects(kb) when is_binary(kb) do
    case Integer.parse(kb) do
      {n, ""} -> loose_objects(n)
      _ -> show(kb)
    end
  end

  def loose_objects(value), do: show(value)

  @doc "The report as indented JSON, for reading."
  def pretty_json(report), do: Poison.encode!(report, pretty: true)

  @doc "Scoring thresholds, sorted for display."
  def thresholds(%{} = config), do: Enum.sort_by(config, fn {k, _} -> k end)
  def thresholds(_), do: []
end
