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
    # One-shot announcement stamps. Set by RC.Discord.RoleSync's
    # periodic tick when the instance state transitions into the
    # matching value. Nil = not yet announced; set = the announcement
    # post went out at that time.
    field(:announced_registration_at, :utc_datetime_usec)
    field(:announced_live_at, :utc_datetime_usec)
    # Operator-entered start time from the /promote modal. The
    # registration announcement renders this (opening_date has never
    # reliably matched real start times).
    field(:announced_start_at, :utc_datetime_usec)
    # Pairwise inter-faction diplomacy channels (matches with > 2
    # factions). `diplo_channels` maps channel name → snowflake string;
    # `diplomacy_category_id` is set only when the bot created its own
    # category (nil = channels live under an operator-owned category),
    # so teardown deletes exactly what the bot created.
    field(:diplomacy_category_id, :string)
    field(:diplo_channels, :map, default: %{})
    # Daily-summary bulletin bookkeeping: the once-a-day posted latch,
    # the cutoff high-water mark of events already summarized, and the
    # random per-match secret seeding the daily slots (stored — never
    # derivable from anything players can observe).
    field(:bulletin_last_posted_on, :date)
    field(:bulletin_cutoff_at, :utc_datetime_usec)
    field(:bulletin_salt, :string)

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
      :role_assignment_active,
      :announced_registration_at,
      :announced_live_at,
      :announced_start_at,
      :diplomacy_category_id,
      :diplo_channels,
      :bulletin_last_posted_on,
      :bulletin_cutoff_at,
      :bulletin_salt
    ])
    |> validate_required([:instance_id, :faction_categories, :promoted_by_discord_id])
    |> unique_constraint(:instance_id)
    |> assoc_constraint(:instance)
  end
end
