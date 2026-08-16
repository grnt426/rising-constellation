defmodule RC.Foresight.SettlementRecord do
  use Ecto.Schema

  import Ecto.Changeset

  @outcomes ~w(settled unbacked void_no_winner void_min_players void_single_faction void_instance_deleted)

  def outcomes, do: @outcomes

  schema "foresight_settlements" do
    field(:instance_id, :integer)
    field(:outcome, :string)
    field(:winning_faction_ref, :string)
    field(:pool_tokens, :integer, default: 0)
    field(:tokens_recovered, :integer, default: 0)
    field(:points_minted, :integer, default: 0)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:instance_id, :outcome, :winning_faction_ref, :pool_tokens, :tokens_recovered, :points_minted])
    |> validate_required([:instance_id, :outcome])
    |> validate_inclusion(:outcome, @outcomes)
    |> unique_constraint(:instance_id)
  end
end
