defmodule RC.Repo.Migrations.AddDiscordLinking do
  use Ecto.Migration

  # Discord account linking.
  #
  # `discord_id` is stored as :string (text), not :decimal like
  # `steam_id` (lib/rc/accounts/account.ex). The reason for the
  # divergence: Discord IDs are 64-bit snowflakes that Discord's own
  # API always returns as strings, because JavaScript can't safely
  # represent 64-bit ints — every Discord SDK on the wire uses
  # strings. Storing as text keeps Nostrum interop friction-free and
  # avoids decimal-string conversions on every read. Numeric ordering
  # of snowflakes has no application meaning here anyway (they encode
  # a timestamp + worker bits, never compared as ranges).
  #
  # `discord_link_codes` is the bridge table for the linking flow:
  # the game website's account settings POSTs to a server endpoint
  # that mints a short opaque code, stores a row, and returns it to
  # the user. The user then runs `/link <code>` in Discord; the bot
  # consumes the row, writes `discord_id` on the account, and the
  # code can never be reused. Codes have a 5-minute TTL (enforced in
  # RC.Accounts.Discord — schema doesn't need an expiry column, just
  # inserted_at + a where-clause).
  #
  # on_delete: :delete_all on account_id — if an account is deleted,
  # its outstanding codes are dead anyway, no point preserving them.
  def change do
    alter table(:accounts) do
      add(:discord_id, :string, null: true)
    end

    # Multiple rows with NULL discord_id are allowed (Postgres default
    # unique-with-nulls semantics); once a value is set, it must be
    # unique across accounts so a single Discord identity can only
    # link to one game account at a time.
    create(unique_index(:accounts, [:discord_id]))

    create table(:discord_link_codes) do
      add(:code, :string, null: false)
      add(:account_id, references(:accounts, on_delete: :delete_all), null: false)
      add(:consumed_at, :utc_datetime_usec, null: true)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    # Primary lookup path: /link <code> resolves the row by exact code.
    create(unique_index(:discord_link_codes, [:code]))

    # Listing / cleanup by account (e.g. "expire prior codes when a
    # new one is minted" — we don't want stacks of valid codes).
    create(index(:discord_link_codes, [:account_id]))

    # Periodic-cleanup sweep: DELETE WHERE inserted_at < now() - 1 hour.
    # Indexed so the sweep stays cheap even after a lot of churn.
    create(index(:discord_link_codes, [:inserted_at]))
  end
end
