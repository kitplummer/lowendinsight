defmodule Lei.ApiKeys do
  import Ecto.Query
  alias Lei.{Repo, Org, ApiKey, RecoveryCode}

  def get_org_by_slug(slug) do
    Repo.get_by(Org, slug: slug)
  end

  @doc """
  Creates an org, refusing to reuse an existing one.

  Any path that **issues credentials without already authenticating the caller**
  must use this rather than `find_or_create_org/2`: signup and ACP completion
  both mint an admin-scoped key for whatever org they are handed, so
  find-or-create semantics let anyone who knows an existing organisation's name
  obtain admin access to it.

  `POST /v1/orgs` is deliberately *not* in that set -- it requires the "admin"
  scope and returns only org metadata, so idempotent creation there is intended.
  """
  def create_org(name, opts \\ []) do
    slug = slugify(name)

    case Repo.get_by(Org, slug: slug) do
      nil ->
        %Org{}
        |> Org.changeset(org_attrs(name, opts))
        |> Repo.insert()

      _existing ->
        {:error, :name_taken}
    end
  end

  @doc """
  Finds an existing org by slug or creates it.

  Only safe where the caller already has authority over the org, or where
  reusing one is intended. **Never** call this from an unauthenticated path that
  goes on to issue credentials -- use `create_org/2`.
  """
  def find_or_create_org(name, opts \\ []) do
    slug = slugify(name)

    case Repo.get_by(Org, slug: slug) do
      nil ->
        %Org{}
        |> Org.changeset(org_attrs(name, opts))
        |> Repo.insert()

      org ->
        {:ok, org}
    end
  end

  @doc "The slug an org named `name` would get; what create_org/2 checks for collisions."
  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # An active Pro org must carry the customer Stripe will bill (Lei.Org), so
  # the caller has to be able to supply it in the same insert. Without that,
  # the only way to create one would be to write an invalid row and correct
  # it, which is the state the constraint exists to forbid.
  defp org_attrs(name, opts) do
    %{
      name: name,
      tier: Keyword.get(opts, :tier, "free"),
      status: Keyword.get(opts, :status, "pending"),
      stripe_customer_id: Keyword.get(opts, :stripe_customer_id)
    }
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

    case Repo.get_by(Org, slug: slug) do
      nil ->
        {:error, :invalid_recovery}

      %Org{} = org ->
        # The code is spent by the update itself, not by a read followed by a
        # write: two requests presenting the same code both passed the
        # `used == false` read and both minted an admin key and rotated the
        # code (security review, 2026-09-14). Only the request whose UPDATE
        # matched a row goes on, and the key and the rotation commit with it,
        # so a failure cannot spend a code without issuing its replacement.
        Repo.transaction(fn ->
          case consume_recovery_code(org.id, code_hash) do
            :ok ->
              {:ok, raw_key, _api_key} =
                create_api_key(org, "recovered-admin", ["admin", "analyze"])

              {:ok, new_recovery_code} = generate_recovery_code(org)
              {raw_key, new_recovery_code}

            :error ->
              Repo.rollback(:invalid_recovery)
          end
        end)
        |> case do
          {:ok, {raw_key, new_recovery_code}} -> {:ok, raw_key, new_recovery_code}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp consume_recovery_code(org_id, code_hash) do
    {count, _} =
      from(r in RecoveryCode,
        where: r.org_id == ^org_id and r.code_hash == ^code_hash and r.used == false
      )
      |> Repo.update_all(set: [used: true])

    if count == 1, do: :ok, else: :error
  end

  def hash_key(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end
end
