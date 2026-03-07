defmodule Lei.ApiKeys do
  import Ecto.Query
  alias Lei.{Repo, Org, ApiKey}

  def find_or_create_org(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    case Repo.get_by(Org, slug: slug) do
      nil ->
        %Org{}
        |> Org.changeset(%{name: name})
        |> Repo.insert()

      org ->
        {:ok, org}
    end
  end

  def create_api_key(org, name, scopes \\ []) do
    raw_key = "lei_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    key_hash = hash_key(raw_key)
    key_prefix = String.slice(raw_key, 0, 8)

    result =
      %ApiKey{}
      |> ApiKey.changeset(%{
        org_id: org.id,
        name: name,
        key_hash: key_hash,
        key_prefix: key_prefix,
        scopes: scopes
      })
      |> Repo.insert()

    case result do
      {:ok, api_key} -> {:ok, raw_key, api_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def authenticate_key(raw_key) do
    key_hash = hash_key(raw_key)

    case Repo.one(from k in ApiKey, where: k.key_hash == ^key_hash and k.active == true, preload: :org) do
      nil -> {:error, :invalid_key}
      api_key -> {:ok, api_key}
    end
  end

  def touch_last_used(%ApiKey{} = api_key) do
    Task.start(fn ->
      api_key
      |> Ecto.Changeset.change(%{last_used_at: DateTime.utc_now()})
      |> Repo.update()
    end)
  end

  def list_keys(%Org{} = org) do
    Repo.all(from k in ApiKey, where: k.org_id == ^org.id, order_by: [desc: :inserted_at])
  end

  def revoke_key(key_id) do
    case Repo.get(ApiKey, key_id) do
      nil ->
        {:error, :not_found}

      api_key ->
        api_key
        |> Ecto.Changeset.change(%{active: false})
        |> Repo.update()
    end
  end

  defp hash_key(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end
end
