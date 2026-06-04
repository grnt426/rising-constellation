defmodule RC.Logs.Log do
  use Ecto.Schema

  import Ecto.Changeset
  import Portal.Gettext

  schema "logs" do
    field(:action, LogAction)
    belongs_to(:account, RC.Accounts.Account)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(log, attrs) do
    log
    |> cast(attrs, [:action, :account_id])
    |> validate_required([:action, :account_id])
  end

  def action_name(:create_account), do: gettext("Account creation")
  def action_name(:login), do: gettext("Login")
  def action_name(:update_restricted), do: gettext("Profile update (restricted)")
  def action_name(:update), do: gettext("Profile update")
  def action_name(:account_validation), do: gettext("Account validation")
  def action_name(:reset_password), do: gettext("Password reset")
  def action_name(_), do: gettext("Unknown action")
end
