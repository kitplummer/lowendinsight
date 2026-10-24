defmodule Lei.Web.Release do
  @moduledoc """
  The release banner every web page shows while the running version is a
  pre-release.

  Separate from the billing banner, which follows `Lei.Billing.mode/0`:
  whether analysis is charged and whether the software is a beta are different
  facts. This one comes from the version, so it disappears with the
  pre-release suffix and nobody has to remember to remove it.
  """

  import Lei.Web.HTML, only: [escape: 1, safe: 1]

  @changelog "https://github.com/kitplummer/lowendinsight/blob/main/apps/lowendinsight/CHANGELOG.md"

  @doc "The running service's version."
  def version, do: Application.spec(:lei_service, :vsn) |> to_string()

  @doc "A SemVer pre-release: anything with a suffix after the patch number."
  def prerelease?(version), do: String.contains?(version, "-")

  @doc "The banner for the running version."
  def banner, do: banner(version())

  @doc "The banner for `version`; empty for a release."
  def banner(version) do
    if prerelease?(version) do
      safe([
        ~s(<div id="release-beta" role="status" style="background:#ffe08a;color:#1a1a1a;),
        ~s(text-align:center;padding:0.4rem 1rem;font-size:0.9rem;line-height:1.4;">),
        ~s(<strong style="letter-spacing:0.08em;">BETA</strong> &middot; ),
        "LowEndInsight v",
        escape(version),
        " is a pre-release. Interfaces and results may change between releases &mdash; ",
        ~s(<a href="#{@changelog}" style="color:#1a1a1a;text-decoration:underline;">what changed</a>),
        "</div>"
      ])
    else
      safe("")
    end
  end
end
