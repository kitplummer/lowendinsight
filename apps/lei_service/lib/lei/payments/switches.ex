defmodule Lei.Payments.Switches do
  @moduledoc """
  The kill switch for each way money comes in (#139, stage F).

    mpp           agents paying by card over MPP
    tempo         agents paying in stablecoin over MPP
    acp           agent card checkout (Lei.Acp)
    pro_checkout  the human Pro plan through Stripe Checkout

  Off means no new payment is offered on that path and nothing is credited
  through it -- including for a challenge or session opened before the switch.
  What happens to money that has already moved differs by path; see
  `Lei.Payments.Held` for stablecoin, and `Lei.StripeWebhookHandler` for Pro.

  Money going back (refunds, disputes) is never switched off.

  Stored in Postgres, append-only: every node reads the same state, a change
  takes effect on the next request without a deploy, and each change records
  who made it and why. A path with no recorded change is on. If the state
  cannot be read, the path is treated as off: a payment path that cannot tell
  whether it has been stopped must not take money.
  """

  import Ecto.Query
  require Logger

  alias Lei.Repo

  @paths ~w(mpp tempo acp pro_checkout)

  defmodule SwitchedOff do
    @moduledoc "Raised where refusing must also make the caller retry later."
    defexception [:path]

    @impl true
    def message(%{path: path}), do: "payment path #{path} is switched off; retry later"
  end

  defmodule Change do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    schema "payment_switches" do
      field(:path, :string)
      field(:enabled, :boolean)
      field(:reason, :string)
      field(:actor, :string)

      timestamps(updated_at: false)
    end

    def changeset(change, attrs) do
      change
      |> cast(attrs, [:path, :enabled, :reason, :actor])
      |> validate_required([:path, :enabled, :reason, :actor])
    end
  end

  def paths, do: @paths

  @doc "Whether `path` is on. Unreadable state counts as off."
  def enabled?(path) when path in @paths do
    case latest(path) do
      nil -> true
      %Change{enabled: enabled} -> enabled
    end
  rescue
    error ->
      Logger.error(
        "Could not read the #{path} payment switch; treating it as off: #{inspect(error)}"
      )

      false
  end

  @doc """
  Switches `path` on or off. `reason` is required: whoever switches it back
  needs to know why it was switched.
  """
  def set(path, enabled, reason, actor)

  def set(path, _enabled, _reason, _actor) when path not in @paths, do: {:error, :unknown_path}

  def set(path, enabled, reason, actor) when is_boolean(enabled) do
    if is_binary(reason) and String.trim(reason) != "" do
      %Change{}
      |> Change.changeset(%{
        path: path,
        enabled: enabled,
        reason: String.trim(reason),
        actor: to_string(actor)
      })
      |> Repo.insert()
      |> tap(fn
        {:ok, _} ->
          Logger.warning(
            "Payment path #{path} switched #{if enabled, do: "ON", else: "OFF"} by #{actor}: #{reason}"
          )

        _ ->
          :ok
      end)
    else
      {:error, :reason_required}
    end
  end

  def set(_path, _enabled, _reason, _actor), do: {:error, :enabled_must_be_boolean}

  @doc "Every path's current state."
  def state do
    Map.new(@paths, fn path ->
      {path,
       case latest(path) do
         nil -> %{enabled: true, reason: nil, actor: nil, changed_at: nil}
         c -> %{enabled: c.enabled, reason: c.reason, actor: c.actor, changed_at: c.inserted_at}
       end}
    end)
  end

  @doc "Every change to `path`, newest first."
  def history(path) when path in @paths do
    Repo.all(from(c in Change, where: c.path == ^path, order_by: [desc: c.id]))
  end

  defp latest(path) do
    Repo.one(from(c in Change, where: c.path == ^path, order_by: [desc: c.id], limit: 1))
  end
end
