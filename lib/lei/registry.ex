defmodule Lei.Registry do
  @moduledoc """
  Resolves package names to source repository URLs by querying package registries.
  Follows the existing patterns in Hex.Scanner, Npm.Scanner, and Pypi.Scanner.
  """
  require Logger

  @spec resolve_repo_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_repo_url(ecosystem, package) do
    HTTPoison.start()

    case ecosystem do
      "hex" -> resolve_hex(package)
      "npm" -> resolve_npm(package)
      "pypi" -> resolve_pypi(package)
      "cargo" -> resolve_cargo(package)
      _ -> {:error, "unsupported ecosystem: #{ecosystem}"}
    end
  end

  defp resolve_hex(package) do
    require HTTPoison.Retry

    response =
      HTTPoison.get!("https://hex.pm/api/packages/#{package}")
      |> HTTPoison.Retry.autoretry(
        max_attempts: 3,
        wait: 5000,
        include_404s: false,
        retry_unknown_errors: false
      )

    case response.status_code do
      200 ->
        links = Poison.decode!(response.body)["meta"]["links"]
        links = for {k, v} <- links, into: %{}, do: {String.downcase(k), v}

        url =
          links["github"] || links["bitbucket"] || links["gitlab"] ||
            links["repository"] || links["source"]

        if url, do: {:ok, url}, else: {:error, "no repo URL for hex/#{package}"}

      status ->
        {:error, "hex.pm returned #{status} for #{package}"}
    end
  rescue
    e -> {:error, "hex lookup failed for #{package}: #{inspect(e)}"}
  end

  defp resolve_npm(package) do
    require HTTPoison.Retry

    encoded = URI.encode(package)

    {:ok, response} =
      HTTPoison.get("https://replicate.npmjs.com/" <> encoded)
      |> HTTPoison.Retry.autoretry(
        max_attempts: 3,
        wait: 5000,
        include_404s: false,
        retry_unknown_errors: false
      )

    case response.status_code do
      200 ->
        decoded = Poison.decode!(response.body)

        case decoded["repository"] do
          %{"url" => url} when is_binary(url) -> {:ok, url}
          _ -> {:error, "no repo URL for npm/#{package}"}
        end

      status ->
        {:error, "npm returned #{status} for #{package}"}
    end
  rescue
    e -> {:error, "npm lookup failed for #{package}: #{inspect(e)}"}
  end

  defp resolve_pypi(package) do
    require HTTPoison.Retry

    encoded = URI.encode(package)

    {:ok, response} =
      HTTPoison.get("https://pypi.org/pypi/" <> encoded <> "/json")
      |> HTTPoison.Retry.autoretry(
        max_attempts: 3,
        wait: 5000,
        include_404s: false,
        retry_unknown_errors: false
      )

    case response.status_code do
      200 ->
        info = Jason.decode!(response.body)["info"]
        urls = info["project_urls"] || %{}

        url =
          urls["Code"] || urls["Source Code"] || urls["Source"] ||
            urls["Repository"] || urls["Homepage"]

        if url, do: {:ok, url}, else: {:error, "no repo URL for pypi/#{package}"}

      status ->
        {:error, "pypi returned #{status} for #{package}"}
    end
  rescue
    e -> {:error, "pypi lookup failed for #{package}: #{inspect(e)}"}
  end

  defp resolve_cargo(package) do
    require HTTPoison.Retry

    {:ok, response} =
      HTTPoison.get("https://crates.io/api/v1/crates/#{package}",
        [{"User-Agent", "lowendinsight/0.9.0"}]
      )
      |> HTTPoison.Retry.autoretry(
        max_attempts: 3,
        wait: 5000,
        include_404s: false,
        retry_unknown_errors: false
      )

    case response.status_code do
      200 ->
        crate = Jason.decode!(response.body)["crate"]
        url = crate["repository"]

        if url, do: {:ok, url}, else: {:error, "no repo URL for cargo/#{package}"}

      status ->
        {:error, "crates.io returned #{status} for #{package}"}
    end
  rescue
    e -> {:error, "cargo lookup failed for #{package}: #{inspect(e)}"}
  end
end
