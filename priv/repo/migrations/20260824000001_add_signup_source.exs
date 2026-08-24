defmodule RC.Repo.Migrations.AddSignupSource do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      # How the account came to exist: "email_signup" (open signup, no
      # referral), "invite" (open signup through a referral link) or
      # "steam". Set server-side at creation; legacy rows stay NULL —
      # they predate the tracking and can't be reliably classified
      # (bots, admin-created, Mailjet-era imports).
      add(:signup_source, :string)
    end
  end
end
