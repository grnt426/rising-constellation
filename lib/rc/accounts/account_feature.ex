defmodule RC.Accounts.AccountFeature do
  @moduledoc """
  Per-account opt-in beta feature flags (Account → Beta Features).

  Deliberately minimal: one row per (account, feature key), enabled boolean.
  The set of valid keys is a code-side whitelist — an unknown key in a
  request is rejected rather than stored, so stale client builds can't
  litter the table.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # Every shippable beta feature. Add new keys here (and a matching toggle
  # in front/src/portal/pages/account/BetaFeatures.vue).
  @known ~w(agent_fan_display calculator mobile_ui)

  def known, do: @known

  schema "account_features" do
    field(:feature, :string)
    field(:enabled, :boolean, default: false)
    belongs_to(:account, RC.Accounts.Account)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(account_feature, attrs) do
    account_feature
    |> cast(attrs, [:account_id, :feature, :enabled])
    |> validate_required([:account_id, :feature, :enabled])
    |> validate_inclusion(:feature, @known)
    |> unique_constraint([:account_id, :feature])
  end
end
