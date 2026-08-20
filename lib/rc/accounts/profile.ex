defmodule RC.Accounts.Profile do
  use Ecto.Schema

  import Ecto.Changeset
  import Filtrex.Type.Config

  schema "profiles" do
    field(:avatar, :string)
    field(:name, :string)
    field(:full_name, :string)
    field(:description, :string)
    field(:long_description, :string)
    # Retired 2026-08: no longer cast, validated, or rendered anywhere.
    # The column sticks around so old rows keep their data until a later
    # cleanup migration drops it for good.
    field(:age, :integer)
    # Flavor fields. favorite_faction is one of the five faction keys
    # ("tetrarchy"..."ark"); favorite_icon is an in-game icon name such as
    # "ship/frigate_1", validated against RC.ProfileIcons. Both optional.
    field(:favorite_faction, :string)
    field(:favorite_icon, :string)
    field(:elo, :float, default: 1200.0)
    # Denormalized from accounts.is_bot. Lets rankings/search hot paths filter
    # bots without joining accounts. Kept in sync at bot-account creation;
    # an account's bot status never changes after creation.
    field(:is_bot, :boolean, default: false)
    belongs_to(:account, RC.Accounts.Account)
    has_many(:registrations, RC.Instances.Registration)

    timestamps(type: :utc_datetime_usec)
  end

  def filter_options do
    defconfig do
      number(:account_id)
      number(:elo)
    end
  end

  # Admin/system changeset. Casts every column including :account_id (for
  # admin-only reassignment) and :elo (for the rating system). Must NOT be
  # used directly with user-supplied params — see `update_changeset/2`.
  @doc false
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :name,
      :avatar,
      :account_id,
      :full_name,
      :description,
      :long_description,
      :favorite_faction,
      :favorite_icon,
      :elo,
      :is_bot
    ])
    |> validate_required([:name, :avatar, :account_id])
    |> shared_validations()
  end

  # User-facing update changeset. Omits :account_id (ownership transfer is
  # admin-only) and :elo (the rating system is the only writer). Used by
  # PUT /api/profiles/:pid so a profile owner can't promote themselves on
  # the leaderboard or detach the profile to another account.
  @doc false
  def update_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name, :avatar, :full_name, :description, :long_description, :favorite_faction, :favorite_icon])
    |> shared_validations()
  end

  defp shared_validations(changeset) do
    changeset
    |> validate_length(:name, max: 30)
    |> RC.DisplayName.validate_display_name(:name)
    |> validate_length(:full_name, max: 120)
    |> validate_length(:description, max: 120)
    |> validate_length(:long_description, max: 1200)
    |> validate_inclusion(:favorite_faction, RC.ProfileIcons.faction_keys())
    |> validate_favorite_icon()
    |> unique_constraint(:name)
  end

  defp validate_favorite_icon(changeset) do
    validate_change(changeset, :favorite_icon, fn :favorite_icon, icon ->
      if RC.ProfileIcons.known?(icon), do: [], else: [favorite_icon: "is not a known icon"]
    end)
  end
end
