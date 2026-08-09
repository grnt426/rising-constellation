defmodule RC.BotAssignments.Assignment do
  @moduledoc """
  One row of the stress-test bot roster. Maps a bot account to the game
  it's currently assigned to, with per-bot policy + session-shape
  overrides.

  Lifecycle: created in `:disabled` state via the dashboard, edited to
  add instance + faction + flip `enabled` to true. The orchestrator
  reads only `enabled: true AND instance_id IS NOT NULL AND faction_id IS
  NOT NULL` rows.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "bot_assignments" do
    field(:enabled, :boolean, default: false)
    field(:policy, :string, default: "RcBot.Policy.Dumb")
    field(:bursts_total, :integer)
    field(:inter_burst_ms_min, :integer)
    field(:inter_burst_ms_max, :integer)
    field(:last_session_at, :utc_datetime_usec)

    belongs_to(:account, RC.Accounts.Account)
    belongs_to(:instance, RC.Instances.Instance)
    belongs_to(:faction, RC.Instances.Faction)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :account_id,
      :instance_id,
      :faction_id,
      :enabled,
      :policy,
      :bursts_total,
      :inter_burst_ms_min,
      :inter_burst_ms_max,
      :last_session_at
    ])
    |> validate_required([:account_id])
    |> validate_length(:policy, max: 128)
    |> validate_number(:bursts_total, greater_than: 0)
    |> validate_number(:inter_burst_ms_min, greater_than_or_equal_to: 0)
    |> validate_number(:inter_burst_ms_max, greater_than_or_equal_to: 0)
    |> validate_inter_burst_range()
    |> validate_account_is_bot()
    |> validate_faction_in_instance()
    |> unique_constraint(:account_id)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:instance_id)
    |> foreign_key_constraint(:faction_id)
  end

  # min must be ≤ max when both are set. Catches a common config slip
  # before the harness picks a weird Process.sleep value.
  defp validate_inter_burst_range(changeset) do
    min_v = get_field(changeset, :inter_burst_ms_min)
    max_v = get_field(changeset, :inter_burst_ms_max)

    if is_integer(min_v) and is_integer(max_v) and min_v > max_v do
      add_error(changeset, :inter_burst_ms_max, "must be >= inter_burst_ms_min")
    else
      changeset
    end
  end

  # Defense-in-depth: even though the dashboard only lets you pick from
  # is_bot accounts, the changeset enforces it at the DB layer too.
  defp validate_account_is_bot(changeset) do
    case get_field(changeset, :account_id) do
      nil ->
        changeset

      account_id ->
        case RC.Repo.get(RC.Accounts.Account, account_id) do
          %{is_bot: true} -> changeset
          %{is_bot: false} -> add_error(changeset, :account_id, "must be a bot account (is_bot=true)")
          nil -> add_error(changeset, :account_id, "account not found")
        end
    end
  end

  # If both instance_id and faction_id are set, the faction must belong
  # to that instance. Prevents "bot in instance 1 but faction 17" data
  # that would explode at runtime when the harness tries to join.
  defp validate_faction_in_instance(changeset) do
    iid = get_field(changeset, :instance_id)
    fid = get_field(changeset, :faction_id)

    cond do
      is_nil(iid) or is_nil(fid) ->
        changeset

      true ->
        case RC.Repo.get(RC.Instances.Faction, fid) do
          %{instance_id: ^iid} -> changeset
          _ -> add_error(changeset, :faction_id, "must belong to the chosen instance")
        end
    end
  end
end
