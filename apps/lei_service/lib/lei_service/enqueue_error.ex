defmodule LeiService.EnqueueError do
  @moduledoc """
  The analysis was charged for and could not be handed to the queue (#217).

  Named rather than a bare `RuntimeError` so the routes can single it out.
  Rescuing every exception would credit back a request whose work *was* queued
  and then failed for some other reason, which is free work.

  Raised for both shapes the insert fails in: a changeset Oban rejects, and a
  database error it raises. The second is the one that matters in practice --
  Oban schema drift, which `LeiService.ObanSchemaVersionTest` exists because
  of, surfaces as a raise rather than an error tuple.
  """
  defexception [:message, :uuid, :reason]

  def exception(opts) do
    uuid = Keyword.get(opts, :uuid)
    reason = Keyword.get(opts, :reason)

    %__MODULE__{
      uuid: uuid,
      reason: reason,
      message: "could not queue the analysis for #{uuid}: #{inspect(reason)}"
    }
  end
end
