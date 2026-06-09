defmodule RC.Discord.Match do
  @moduledoc """
  Bookkeeping row for an instance that has been promoted to a
  community-wide Discord match via `/promote legacy`.

  Created by `RC.Discord.LegacyMatch.promote/2` after channel creation
  succeeds. One row per instance (unique constraint on `instance_id`).

  ## Fields

    * `instance_id` — FK into instances. `on_delete: :delete_all` on
      the DB side, so deleting an instance purges its match row.
    * `faction_categories` — JSONB map keyed by `faction_ref` string
      (e.g., `"tetrarchy"`, `"myrmezir"`) whose value is the Discord
      category snowflake (string). One key per faction in the
      instance — not always all 5; depends on the scenario.
    * `promoted_by_discord_id` — audit field; whose `/promote` did
      this. String form of the Discord user id.
    * `role_assignment_active` — Phase 2 gate. Starts false; flipped
      to true at `opening_date - 6h` by the periodic sweep, at which
      point faction roles start being assigned in Discord.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "discord_matches" do
    field(:faction_categories, :map, default: %{})
    field(:promoted_by_discord_id, :string)
    field(:role_assignment_active, :boolean, default: false)

    belongs_to(:instance, RC.Instances.Instance)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(match, attrs) do
    match
    |> cast(attrs, [
      :instance_id,
      :faction_categories,
      :promoted_by_discord_id,
      :role_assignment_active
    ])
    |> validate_required([:instance_id, :faction_categories, :promoted_by_discord_id])
    |> unique_constraint(:instance_id)
    |> assoc_constraint(:instance)
  end
end
