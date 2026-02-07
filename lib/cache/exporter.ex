# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Cache.Exporter do
  @moduledoc """
  Exports LEI analysis reports as cache snapshot files.

  Generates two files in an export directory:
  - `manifest.json` - Metadata about the cache snapshot
  - `cache.jsonl.gz` - Gzipped JSONL of analysis reports

  These files can then be packaged as an OCI artifact via `Lei.Cache.OCI`.
  """

  require Logger

  @doc """
  Exports a list of analysis reports to the given directory.

  Each report should be a map as returned by `AnalyzerModule.analyze/3`.
  Creates `manifest.json` and `cache.jsonl.gz` in `output_dir`.
  """
  @spec export([map()], String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def export(reports, output_dir, opts \\ []) do
    File.mkdir_p!(output_dir)

    date = Keyword.get(opts, :date, Date.to_iso8601(Date.utc_today()))

    jsonl = reports_to_jsonl(reports)
    compressed = :zlib.gzip(jsonl)

    jsonl_gz_path = Path.join(output_dir, "cache.jsonl.gz")
    File.write!(jsonl_gz_path, compressed)

    manifest = build_manifest(reports, date, byte_size(jsonl), byte_size(compressed))
    manifest_json = Poison.encode!(manifest, pretty: true)

    manifest_path = Path.join(output_dir, "manifest.json")
    File.write!(manifest_path, manifest_json)

    Logger.info("Cache exported to #{output_dir}: #{length(reports)} entries, #{byte_size(compressed)} bytes compressed")

    {:ok, output_dir}
  end

  @doc """
  Reads analysis reports from a JSONL file (plain or gzipped).
  """
  @spec read_jsonl(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def read_jsonl(path) do
    with {:ok, raw} <- File.read(path) do
      data =
        if String.ends_with?(path, ".gz") do
          :zlib.gunzip(raw)
        else
          raw
        end

      reports =
        data
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case Poison.decode(line) do
            {:ok, parsed} -> parsed
            {:error, _} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, reports}
    else
      {:error, reason} -> {:error, "Cannot read #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Converts a list of reports to newline-delimited JSON (JSONL).
  """
  @spec reports_to_jsonl([map()]) :: binary()
  def reports_to_jsonl(reports) do
    reports
    |> Enum.map(&Poison.encode!/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp build_manifest(reports, date, raw_size, compressed_size) do
    repos =
      reports
      |> Enum.map(fn report ->
        get_in_flexible(report, [:data, :repo]) ||
          get_in_flexible(report, [:header, :repo]) ||
          "unknown"
      end)
      |> Enum.uniq()

    %{
      "format_version" => "1.0",
      "lei_version" => lowendinsight_version(),
      "created" => DateTime.to_iso8601(DateTime.utc_now()),
      "date" => date,
      "entry_count" => length(reports),
      "repos" => repos,
      "raw_size" => raw_size,
      "compressed_size" => compressed_size,
      "content_hash" =>
        :crypto.hash(:sha256, Enum.map(reports, &Poison.encode!/1) |> Enum.join())
        |> Base.encode16(case: :lower)
    }
  end

  defp get_in_flexible(map, keys) when is_map(map) do
    Enum.reduce_while(keys, map, fn key, acc ->
      cond do
        is_map(acc) && Map.has_key?(acc, key) -> {:cont, Map.get(acc, key)}
        is_map(acc) && Map.has_key?(acc, to_string(key)) -> {:cont, Map.get(acc, to_string(key))}
        true -> {:halt, nil}
      end
    end)
  end

  defp lowendinsight_version do
    case :application.get_key(:lowendinsight, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.9.0"
    end
  end
end
