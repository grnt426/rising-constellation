defmodule RC.Foresight.Prediction do
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(active correct incorrect void)

  def statuses, do: @statuses

  schema "foresight_predictions" do
    # Plain integers, not belongs_to — instances (and their factions)
    # are deletable while predictions must survive as history. See the
    # migration for the full rationale.
    field(:instance_id, :integer)
    field(:faction_id, :integer)
    field(:faction_ref, :string)
    field(:tokens, :integer)
    field(:credited_tokens, :integer, default: 0)
    field(:status, :string, default: "active")
    field(:tokens_recovered, :integer)
    field(:bonus_tokens, :integer, default: 0)
    field(:points_awarded, :integer)
    field(:settled_at, :utc_datetime_usec)

    belongs_to(:account, RC.Accounts.Account)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(prediction, attrs) do
    prediction
    |> cast(attrs, [:account_id, :instance_id, :faction_id, :faction_ref, :tokens, :credited_tokens])
    |> validate_required([:account_id, :instance_id, :faction_id, :faction_ref, :tokens])
    |> validate_number(:tokens, greater_than: 0)
    |> validate_number(:credited_tokens, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:account_id)
    |> unique_constraint(:account_id, name: :foresight_predictions_one_active_courtesy)
  end
end
