defmodule RC.Instances.Instance do
  use Ecto.Schema

  import Ecto.Changeset
  import Filtrex.Type.Config
  import Portal.Gettext

  schema "instances" do
    field(:game_data, :map)
    field(:game_metadata, :map)
    field(:name, :string)
    field(:description, :string)
    field(:opening_date, :utc_datetime_usec)
    field(:registration_type, InstanceRegistrationType)
    field(:registration_status, InstanceRegistrationStatus)
    field(:start_setting, ScenarioStartSettings)
    field(:game_type, InstanceGameType)
    field(:public, :boolean)
    # Bot-only games are hidden from non-admin listing paths. Bots in
    # them still join channels normally; this only affects /api/instances
    # discovery surface so they don't appear in the real-player lobby.
    field(:is_bot_only, :boolean, default: false)
    # Per-match Discord promotion flag. When true, this instance is eligible
    # for `/promote legacy` (community Discord faction chats). Set on the
    # game-setup page at creation (admin-only UI) and read by
    # RC.Discord.LegacyMatch.list_eligible/0. Moved here from
    # scenarios.discord_ready so promotability is a per-match decision, not a
    # property of the scenario template.
    field(:discord_ready, :boolean, default: false)
    field(:state, :string)
    field(:node, :string, virtual: true)
    # Live supervisor state, derived at read time via Instance.Manager.get_status/1
    # and stamped onto the struct by RC.Instances.put_instance_supervisor_status/1.
    # Declared here so callers (e.g. Portal.InstancesLive.maybe_destroy_supervisor/1)
    # can struct-pattern-match `%Instance{supervisor_status: :not_instantiated}`
    # without an "unknown key" compile error. Defaults to nil — pattern matches
    # against specific atoms safely fall through when the helper hasn't run.
    field(:supervisor_status, InstanceSupervisorStatus, virtual: true)
    belongs_to(:account, RC.Accounts.Account)
    # Stage 4 (mini) — back-reference to the scenario that spawned this
    # instance. Nullable for legacy rows + because the scenario may have
    # been deleted out from under us (on_delete: :nilify_all). Set on
    # `RC.Instances.create_instance/3`, never re-cast by the user-facing
    # changesets.
    belongs_to(:scenario, RC.Scenarios.Scenario)
    has_one(:victory, RC.Instances.Victory)
    has_many(:factions, RC.Instances.Faction, on_delete: :delete_all)
    has_many(:player_stats, RC.Instances.PlayerStat)
    has_many(:snapshots, RC.Instances.InstanceSnapshot)
    has_many(:states, RC.Instances.InstanceState, on_delete: :delete_all)
    many_to_many(:groups, RC.Groups.Group, join_through: "instance_groups", on_delete: :delete_all)

    timestamps(type: :utc_datetime_usec)
  end

  def filter_options do
    # additional filters can be found in RC.Instances.put_instance_json_filters/2
    defconfig do
      number(:id)
      date(:opening_date, format: "{0M}-{0D}-{YYYY}")
      boolean(:public)
      text(:name)
      text(:state)
    end
  end

  # Admin/system changeset. Casts :state and :account_id which let an
  # admin reassign instance ownership and the supervisor lifecycle code
  # write state transitions. Must NOT be reached from user-supplied
  # params — `update_changeset/2` is the user-facing version.
  @doc false
  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :name,
      :game_data,
      :game_metadata,
      :opening_date,
      :registration_type,
      :registration_status,
      :start_setting,
      :game_type,
      :description,
      :public,
      :account_id,
      :scenario_id,
      :state,
      :is_bot_only,
      :discord_ready
    ])
    |> validate_required([
      :name,
      :game_data,
      :game_metadata,
      :opening_date,
      :registration_type,
      :registration_status,
      :start_setting,
      :game_type,
      :description,
      :public,
      :account_id
    ])
    |> shared_validations()
  end

  # User-facing update changeset. Omits :state (state machine is the only
  # writer — use the explicit /start, /pause, /finish, etc. endpoints) and
  # :account_id (ownership transfer is admin-only). Used by PUT
  # /api/instances/:iid so an owner can't end a running game by writing
  # {"state": "ended"} or hand their instance to another account.
  #
  # validate_required mirrors `changeset/2`'s required set (minus :account_id,
  # which isn't cast here) so PUT {"name": null, ...} surfaces a 400 changeset
  # error instead of a 500 from the underlying NOT NULL constraint.
  @doc false
  def update_changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :name,
      :game_data,
      :game_metadata,
      :opening_date,
      :registration_type,
      :registration_status,
      :start_setting,
      :game_type,
      :description,
      :public
    ])
    |> validate_required([
      :name,
      :game_data,
      :game_metadata,
      :opening_date,
      :registration_type,
      :registration_status,
      :start_setting,
      :game_type,
      :description,
      :public
    ])
    |> shared_validations()
  end

  defp shared_validations(changeset) do
    changeset
    |> validate_length(:name, max: 120)
    |> RC.DisplayName.validate_display_name(:name)
    |> validate_length(:description, max: 5_000)
  end

  def state_name("created"), do: gettext("Created")
  def state_name("open"), do: gettext("Open")
  def state_name("running"), do: gettext("Running")
  def state_name("not_running"), do: gettext("Stopped")
  def state_name("maintenance"), do: gettext("In maintenance")
  def state_name("paused"), do: gettext("Paused")
  def state_name("ended"), do: gettext("Ended")
  def state_name(_), do: ""

  def state_color("created"), do: "is-grey"
  def state_color("open"), do: "is-grey"
  def state_color("running"), do: "is-green-1"
  def state_color("not_running"), do: "is-red-2"
  def state_color("maintenance"), do: "is-red-1"
  def state_color("paused"), do: "is-blue-1"
  def state_color("ended"), do: "is-grey"
  def state_color(_), do: ""
end
