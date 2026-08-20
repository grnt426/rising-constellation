defmodule RC.Accounts.DeletionRequest do
  @moduledoc """
  Audit row for account-deletion requests (CCPA-style record keeping).

  Intentionally data-minimal: a sha256 of the email rather than the address,
  plus lifecycle timestamps (`inserted_at` = requested). Rows outlive the
  account scrub — after purge the linked account row is anonymized, so the
  trail proves the request was honored without retaining who it was.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "deletion_requests" do
    field(:email_hash, :string)
    field(:source, :string, default: "self_service")
    field(:confirmed_at, :utc_datetime_usec)
    field(:cancelled_at, :utc_datetime_usec)
    field(:purged_at, :utc_datetime_usec)
    belongs_to(:account, RC.Accounts.Account)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(request, attrs) do
    request
    |> cast(attrs, [:account_id, :email_hash, :source, :confirmed_at, :cancelled_at, :purged_at])
    |> validate_required([:account_id, :email_hash])
  end
end
