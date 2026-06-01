defmodule RC.Repo.Migrations.AddTokenVersionToAccounts do
  use Ecto.Migration

  # Per-account JWT revocation primitive. `RC.Guardian` embeds the current
  # value as the "tv" claim on issued tokens and rejects any token whose
  # claim doesn't match. Bump the column to immediately invalidate every
  # outstanding token for the account (logout, password change, ban).
  def change do
    alter table(:accounts) do
      add :token_version, :integer, null: false, default: 0
    end
  end
end
