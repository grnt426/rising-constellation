defmodule RC.Repo.Migrations.AddInviteFieldsToAccounts do
  use Ecto.Migration

  # Invite-link signup.
  #
  # `referred_by_id` records which existing account's invite link the new
  # user redeemed. Nullable: Steam signups, pre-existing accounts, and
  # any future non-invite path leave it null. on_delete: :nilify_all so
  # deleting the inviter doesn't cascade-delete every account they invited.
  #
  # `can_create_account_invites` is the per-account kill-switch admins
  # flip when an account starts generating invites that feed spammers --
  # the account stays otherwise functional but can no longer mint links.
  def change do
    alter table(:accounts) do
      add :referred_by_id,
          references(:accounts, on_delete: :nilify_all),
          null: true

      add :can_create_account_invites, :boolean,
          null: false, default: true
    end

    create index(:accounts, [:referred_by_id])
  end
end
