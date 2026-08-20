defmodule RC.Repo.Migrations.AddAccountDeletion do
  use Ecto.Migration

  # ALTER TYPE ... ADD VALUE cannot run inside a transaction block.
  @disable_ddl_transaction true

  def up do
    execute("ALTER TYPE token_type ADD VALUE IF NOT EXISTS 'account_deletion'")

    alter table(:accounts) do
      # Non-nil = deletion confirmed and the grace-period clock is running.
      # Deliberately NOT castable through any public changeset — only
      # RC.Accounts.Deletion touches it.
      add(:deletion_requested_at, :utc_datetime_usec)
    end

    # Audit trail for deletion requests (CCPA-style record keeping).
    # Data-minimal: sha256 of the email, never the address itself.
    create table(:deletion_requests) do
      add(:account_id, references(:accounts, on_delete: :nilify_all))
      add(:email_hash, :string)
      add(:source, :string, default: "self_service")
      add(:confirmed_at, :utc_datetime_usec)
      add(:cancelled_at, :utc_datetime_usec)
      add(:purged_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:deletion_requests, [:account_id]))

    create(
      index(:accounts, [:deletion_requested_at],
        where: "deletion_requested_at IS NOT NULL",
        name: :accounts_deletion_pending_index
      )
    )
  end

  def down do
    drop(index(:accounts, [:deletion_requested_at], name: :accounts_deletion_pending_index))
    drop(table(:deletion_requests))

    alter table(:accounts) do
      remove(:deletion_requested_at)
    end

    # The 'account_deletion' enum value stays — Postgres cannot drop enum
    # values, and leaving it is harmless.
  end
end
