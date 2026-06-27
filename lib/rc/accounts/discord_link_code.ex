defmodule RC.Accounts.DiscordLinkCode do
  @moduledoc """
  Short-lived one-time token used to bridge a logged-in game session
  to a Discord interaction.

  Lifecycle:

    1. Player clicks "Link Discord" in the game's account settings.
       The web POSTs to `/api/discord/link-code`, which calls
       `RC.Accounts.Discord.generate_code/1` to insert a row here
       and returns the code to the browser.

    2. Player switches to Discord and runs `/link <code>`.
       `RC.Accounts.Discord.consume_code/2` looks up the row,
       validates not-consumed + not-expired, and atomically marks
       it consumed while writing `discord_id` onto the account.

  TTL (5 minutes) is enforced in the business module, not the schema —
  it's just a `WHERE inserted_at > now() - interval`. Expired rows
  remain in the table until a cleanup sweep removes them; they can't
  be used because the validity check rejects them on read.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "discord_link_codes" do
    field(:code, :string)
    field(:consumed_at, :utc_datetime_usec)
    belongs_to(:account, RC.Accounts.Account)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(link_code, attrs) do
    link_code
    |> cast(attrs, [:code, :account_id, :consumed_at])
    |> validate_required([:code, :account_id])
    |> unique_constraint(:code)
    |> assoc_constraint(:account)
  end
end
