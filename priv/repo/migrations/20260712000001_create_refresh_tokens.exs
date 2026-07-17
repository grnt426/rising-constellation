defmodule RC.Repo.Migrations.CreateRefreshTokens do
  use Ecto.Migration

  # Server-side rotation state for refresh JWTs. One row per issued refresh
  # token, keyed by the token's "jti" claim. `rotated_at` NULL means the
  # token is the family's current credential; a non-NULL value marks it as
  # spent — re-presenting it after the rotation grace window is treated as
  # theft and bumps `accounts.token_version` (killing every outstanding
  # token for the account). Tokens minted before this table existed have
  # no row and keep working untracked until their 30-day exp.
  def change do
    create table(:refresh_tokens, primary_key: false) do
      add(:jti, :string, primary_key: true)
      add(:account_id, references(:accounts, on_delete: :delete_all), null: false)
      add(:family, :string, null: false)
      add(:rotated_at, :utc_datetime)
      add(:expires_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:refresh_tokens, [:account_id]))
  end
end
