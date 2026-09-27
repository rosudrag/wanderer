defmodule WandererApp.Identity.Audit do
  @moduledoc """
  Thin wrapper around `WandererApp.Api.AuditLog.create/1` — every mutation
  in docs/chewy/corp-suite-plan.md §2.8 calls this instead of creating the
  resource row directly, so the shape stays uniform. Never raises: a
  failed audit write is logged but does not roll back the mutation it was
  describing.
  """

  require Logger

  def log!(attrs) do
    case WandererApp.Api.AuditLog.create(attrs) do
      {:ok, entry} ->
        entry

      {:error, error} ->
        Logger.error("[Identity.Audit] failed to write audit log: #{inspect(error)}")
        nil
    end
  end
end
