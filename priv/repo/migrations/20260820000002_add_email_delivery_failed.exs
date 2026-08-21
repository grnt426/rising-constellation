defmodule RC.Repo.Migrations.AddEmailDeliveryFailed do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      # Stamped by POST /api/mail/events on SES hard bounces (see
      # RC.Accounts.mark_email_delivery_failed/1); read by the portal's
      # verify-email banner. Cleared when the account's email changes.
      add(:email_delivery_failed_at, :utc_datetime_usec)
    end
  end
end
