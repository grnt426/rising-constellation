defmodule RC.Deploy.Log do
  use Ecto.Schema

  import Ecto.Changeset

  # `source` records who flipped the flag: "script" (the deploy script's
  # rpc), "discord:<snowflake>" (/cleardeploy), etc. Append-only — the
  # newest row is the current flag state (same idiom as maintenance_log).
  schema "deploy_log" do
    field(:flag, :boolean)
    field(:source, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(log, attrs) do
    log
    |> cast(attrs, [:flag, :source])
    |> validate_required([:flag, :source])
    |> validate_length(:source, max: 255)
  end
end
