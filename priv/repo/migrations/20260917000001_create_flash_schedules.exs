defmodule RC.Repo.Migrations.CreateFlashSchedules do
  use Ecto.Migration

  # Scheduled Flash matches (RC.FlashSchedules):
  #
  # * flash_schedules — admin-defined weekly slots. Times are US Eastern
  #   wall-clock (DST-aware). The map pool rotates in order, one map per
  #   week counted from anchor_date.
  # * flash_scheduled_matches — one row per created occurrence; the unique
  #   (schedule_id, scheduled_start_at) index makes creation idempotent
  #   across scheduler ticks and restarts.
  # * registrations.ready_at — the scheduled lobby's ready-up flag.
  def change do
    create table(:flash_schedules) do
      add(:name, :string, null: false)
      add(:description, :text, null: false, default: "")
      add(:enabled, :boolean, null: false, default: true)
      # ISO weekday, 1 = Monday .. 7 = Sunday.
      add(:weekday, :integer, null: false)
      # US Eastern wall-clock start.
      add(:start_time, :time, null: false)
      # Map pool (scenario ids), rotated in order.
      add(:scenario_ids, {:array, :integer}, null: false, default: [])
      # nil = keep each scenario's own mutators; [] = none; otherwise these.
      add(:mutator_keys, {:array, :string})
      add(:game_mode_type, :string, null: false, default: "casual")
      add(:min_players, :integer, null: false, default: 2)
      # Seats per faction; nil = the New Game default for the map.
      add(:faction_capacity, :integer)
      # Week 0 of the map rotation.
      add(:anchor_date, :date, null: false)
      add(:account_id, references(:accounts, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec)
    end

    create table(:flash_scheduled_matches) do
      add(:schedule_id, references(:flash_schedules, on_delete: :nilify_all))
      add(:instance_id, references(:instances, on_delete: :delete_all), null: false)
      add(:scheduled_start_at, :utc_datetime_usec, null: false)
      # open | starting | started | expired
      add(:status, :string, null: false, default: "open")
      # Copied from the schedule at creation: later edits don't move the
      # goalposts of a lobby that is already up.
      add(:min_players, :integer, null: false, default: 2)
      add(:announced_at, :utc_datetime_usec)
      add(:started_at, :utc_datetime_usec)
      add(:started_by_account_id, references(:accounts, on_delete: :nilify_all))
      add(:result_posted_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:flash_scheduled_matches, [:schedule_id, :scheduled_start_at]))
    create(unique_index(:flash_scheduled_matches, [:instance_id]))
    create(index(:flash_scheduled_matches, [:status]))

    alter table(:registrations) do
      add(:ready_at, :utc_datetime_usec)
    end
  end
end
