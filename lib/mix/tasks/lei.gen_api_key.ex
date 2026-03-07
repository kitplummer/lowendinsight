defmodule Mix.Tasks.Lei.GenApiKey do
  @moduledoc "Generate an API key for an org: mix lei.gen_api_key --org \"My Org\" --name \"ci-key\" --scopes \"analyze,cache\""
  @shortdoc "Generate an API key for an org"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [org: :string, name: :string, scopes: :string])

    org_name = opts[:org] || Mix.raise("--org is required")
    key_name = opts[:name] || Mix.raise("--name is required")

    scopes =
      case opts[:scopes] do
        nil -> []
        s -> String.split(s, ",", trim: true)
      end

    Mix.Task.run("app.start")

    {:ok, org} = Lei.ApiKeys.find_or_create_org(org_name)
    {:ok, raw_key, api_key} = Lei.ApiKeys.create_api_key(org, key_name, scopes)

    Mix.shell().info("""

    API key created successfully!

      Org:     #{org.name} (#{org.slug})
      Name:    #{api_key.name}
      Scopes:  #{Enum.join(api_key.scopes, ", ")}
      Key:     #{raw_key}

    WARNING: This key will not be shown again. Store it securely.
    """)
  end
end
