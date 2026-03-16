defmodule Lei.ApiKeys do
  import Ecto.Query
  alias Lei.{Repo, Org, ApiKey, RecoveryCode}

  def get_org_by_slug(slug) do
    Repo.get_by(Org, slug: slug)
  end

  def find_or_create_org(name, opts \\ []) do
    tier = Keyword.get(opts, :tier, "free")
    status = Keyword.get(opts, :status, "pending")

    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    case Repo.get_by(Org, slug: slug) do
      nil ->
        %Org{}
        |> Org.changeset(%{name: name, tier: tier, status: status})
        |> Repo.insert()

      org ->
        {:ok, org}
    end
  end

  def activate_org(%Org{} = org) do
    org
    |> Org.activate_changeset()
    |> Repo.update()
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

    case Repo.one(
           from(k in ApiKey, where: k.key_hash == ^key_hash and k.active == true, preload: :org)
         ) do
      nil ->
        {:error, :invalid_key}

      api_key ->
        case api_key.org.status do
          "active" -> {:ok, api_key}
          status -> {:error, {:org_not_active, status}}
        end
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
    Repo.all(from(k in ApiKey, where: k.org_id == ^org.id, order_by: [desc: :inserted_at]))
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

  # --- Recovery codes ---

  def generate_recovery_code(org) do
    raw_code = "lei_recover_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    code_hash = hash_key(raw_code)

    result =
      %RecoveryCode{}
      |> RecoveryCode.changeset(%{org_id: org.id, code_hash: code_hash})
      |> Repo.insert()

    case result do
      {:ok, _record} -> {:ok, raw_code}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def recover_with_code(slug, raw_code) do
    code_hash = hash_key(raw_code)

    with %Org{} = org <- Repo.get_by(Org, slug: slug),
         %RecoveryCode{} = rc <-
           Repo.one(
             from(r in RecoveryCode,
               where: r.code_hash == ^code_hash and r.org_id == ^org.id and r.used == false
             )
           ) do
      # Mark old code as used
      rc |> Ecto.Changeset.change(%{used: true}) |> Repo.update!()

      # Create new admin key
      {:ok, raw_key, _api_key} = create_api_key(org, "recovered-admin", ["admin", "analyze"])

      # Generate new recovery code (rotation)
      {:ok, new_recovery_code} = generate_recovery_code(org)

      {:ok, raw_key, new_recovery_code}
    else
      nil -> {:error, :invalid_recovery}
    end
  end

  def hash_key(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end
end
