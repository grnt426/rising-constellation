defmodule RC.Maintenance.Log do
  use Ecto.Schema

  import Ecto.Changeset

  # The table also has a `min_client_version` column from the retired
  # minimum-client-version setting (the client now compares builds via
  # GET /api/version, RC.Build). It is left out of the schema so new rows
  # take its database default.
  schema "maintenance_log" do
    field(:flag, :boolean)
    belongs_to(:account, RC.Accounts.Account)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(log, attrs) do
    log
    |> cast(attrs, [:flag, :account_id])
    |> validate_required([:flag, :account_id])
  end
end
