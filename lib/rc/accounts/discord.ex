defmodule RC.Accounts.Discord do
  @moduledoc """
  Business logic for linking a game account to a Discord identity.

  The flow lives in three pieces:

    * `generate_code/1` — called from the game web (account settings)
      by an authenticated user. Mints a fresh short opaque code,
      attaches it to the account, returns it so the browser can show
      it to the user.

    * `consume_code/2` — called from the Discord bot when a user runs
      `/link <code>`. Validates the code (exists, not consumed, not
      expired), then in a single transaction marks the code consumed
      and writes `discord_id` onto the account.

    * `unlink/1` — clears `discord_id`. Called from `/unlink` in
      Discord (and reusable from a web "unlink" button later).

  Plus `get_account_by_discord_id/1` for the rest of the bot.

  ## Code format & security

  Codes are 8 characters from a Crockford-style alphabet
  (`23456789ABCDEFGHJKLMNPQRSTUVWXYZ` — no `O/0`, no `I/L/1`),
  displayed as `XXXX-XXXX`. That's 32^8 ≈ 1.1 trillion combinations.
  Combined with the 5-minute TTL and the rate-limiting on
  `POST /api/discord/link-code` (handled at the controller / pipeline
  layer, not here), brute force is not a meaningful threat.

  When matching incoming input, `normalize_code/1` upper-cases and
  strips any non-alphanumeric characters, then re-inserts the dash
  if the remainder is 8 chars. So a user who types `k7qf 93mr` or
  `K7QF93MR` ends up matching the stored `K7QF-93MR`.

  ## Race-safety

  `consume_code/2` runs the "mark consumed" + "set discord_id" as a
  single Ecto.Multi transaction. If the discord_id write fails
  (typically because that Discord identity is already linked to a
  different game account — caught by the unique constraint on
  `accounts.discord_id`), the whole thing rolls back, including the
  consumed_at flag, so the user can try again with a different
  Discord account (or unlink the other game account first).
  """

  require Logger

  import Ecto.Query

  alias Ecto.Multi
  alias RC.Accounts.Account
  alias RC.Accounts.DiscordLinkCode
  alias RC.Repo

  # 5-minute window from code mint to code consumption. Generous
  # enough for a player to alt-tab to Discord; short enough that a
  # leaked code dies quickly.
  @code_ttl_seconds 5 * 60

  # No O/0, no I/L/1 — easy to read aloud and to type from a phone.
  @code_alphabet ~c"23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
  @code_body_length 8

  # --- generate_code/1 ------------------------------------------------

  @doc """
  Mint a fresh code for the given account. Best-effort expires any
  prior unconsumed codes for the same account (one live code at a
  time keeps the table tidy and avoids "which code did I use" UX).

  Returns `{:ok, code_string}` ready to display, or
  `{:error, changeset}` on insert failure.
  """
  @spec generate_code(integer()) :: {:ok, String.t()} | {:error, Ecto.Changeset.t()}
  def generate_code(account_id) when is_integer(account_id) do
    expire_outstanding_codes(account_id)
    code = random_code()

    %DiscordLinkCode{}
    |> DiscordLinkCode.changeset(%{code: code, account_id: account_id})
    |> Repo.insert()
    |> case do
      {:ok, _link_code} -> {:ok, code}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # --- consume_code/2 -------------------------------------------------

  @doc """
  Consume a code (from `/link`) and write `discord_id` onto the
  corresponding account.

  ## Returns

    * `{:ok, account}` — linked successfully
    * `{:error, :not_found}` — no row matches the (normalized) code
    * `{:error, :already_consumed}` — code was used before
    * `{:error, :expired}` — code is older than the TTL window
    * `{:error, :discord_already_linked}` — this Discord identity
      is already attached to a different game account
    * `{:error, {:changeset, changeset}}` — other validation failure
    * `{:error, :transaction_failed}` — unexpected
  """
  @spec consume_code(String.t(), String.t() | integer()) ::
          {:ok, Account.t()}
          | {:error,
             :not_found
             | :already_consumed
             | :expired
             | :discord_already_linked
             | :transaction_failed
             | {:changeset, Ecto.Changeset.t()}}
  def consume_code(raw_input, discord_id) when is_binary(raw_input) do
    code = normalize_code(raw_input)
    discord_id_str = to_string(discord_id)

    with {:ok, link_code} <- fetch_valid_code(code) do
      account = Repo.get!(Account, link_code.account_id)

      Multi.new()
      |> Multi.update(
        :link_code,
        DiscordLinkCode.changeset(link_code, %{consumed_at: DateTime.utc_now()})
      )
      |> Multi.update(:account, Account.changeset_discord_id(account, discord_id_str))
      |> Repo.transaction()
      |> case do
        {:ok, %{account: updated_account}} ->
          Logger.info(
            "[RC.Accounts.Discord] linked account #{updated_account.id} to discord_id=#{discord_id_str}"
          )

          {:ok, updated_account}

        {:error, :account, changeset, _changes} ->
          if discord_id_unique_violation?(changeset) do
            {:error, :discord_already_linked}
          else
            {:error, {:changeset, changeset}}
          end

        {:error, _step, _value, _changes} ->
          {:error, :transaction_failed}
      end
    end
  end

  # --- unlink/1 -------------------------------------------------------

  @doc """
  Clear `discord_id` on the given account.

  Returns `{:ok, account}` on success, `{:error, :not_linked}` if the
  account didn't have a Discord ID to begin with, or
  `{:error, :account_not_found}` if the account doesn't exist.

  Used by `/unlink` in the bot, and reusable from a web "Unlink
  Discord" button if/when that's added.
  """
  @spec unlink(integer()) ::
          {:ok, Account.t()} | {:error, :not_linked | :account_not_found | Ecto.Changeset.t()}
  def unlink(account_id) when is_integer(account_id) do
    case Repo.get(Account, account_id) do
      nil ->
        {:error, :account_not_found}

      %Account{discord_id: nil} ->
        {:error, :not_linked}

      account ->
        account
        |> Account.changeset_discord_id(nil)
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            Logger.info("[RC.Accounts.Discord] unlinked account #{updated.id}")
            {:ok, updated}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Look up an account by Discord user ID. Returns the account or nil.
  Used by other parts of the bot to answer "which player is this
  Discord user?".
  """
  @spec get_account_by_discord_id(String.t() | integer()) :: Account.t() | nil
  def get_account_by_discord_id(discord_id) when is_binary(discord_id) or is_integer(discord_id) do
    Repo.get_by(Account, discord_id: to_string(discord_id))
  end

  # --- code normalization (public for testability) --------------------

  @doc """
  Normalize user input into the canonical code form.

  Uppercases, strips any non-alphanumeric character, and if the
  result is exactly 8 chars, re-inserts a dash between the two
  groups of 4 so it matches the format we store.

  Permissive on purpose — users will paste with extra whitespace, the
  dash misaligned, lowercase, etc.
  """
  @spec normalize_code(any()) :: String.t()
  def normalize_code(input) do
    stripped =
      input
      |> to_string()
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]/, "")

    case stripped do
      <<a::binary-size(4), b::binary-size(4)>> -> a <> "-" <> b
      other -> other
    end
  end

  # --- Internal -------------------------------------------------------

  defp fetch_valid_code(code) do
    case Repo.get_by(DiscordLinkCode, code: code) do
      nil ->
        {:error, :not_found}

      %DiscordLinkCode{consumed_at: %DateTime{}} ->
        {:error, :already_consumed}

      %DiscordLinkCode{inserted_at: inserted_at} = link_code ->
        if DateTime.diff(DateTime.utc_now(), inserted_at) > @code_ttl_seconds do
          {:error, :expired}
        else
          {:ok, link_code}
        end
    end
  end

  defp expire_outstanding_codes(account_id) do
    now = DateTime.utc_now()

    from(c in DiscordLinkCode,
      where: c.account_id == ^account_id and is_nil(c.consumed_at)
    )
    |> Repo.update_all(set: [consumed_at: now])
  end

  defp random_code do
    alphabet = @code_alphabet
    alphabet_size = length(alphabet)

    chars =
      :crypto.strong_rand_bytes(@code_body_length)
      |> :binary.bin_to_list()
      |> Enum.map(fn b -> Enum.at(alphabet, rem(b, alphabet_size)) end)
      |> List.to_string()

    String.slice(chars, 0..3) <> "-" <> String.slice(chars, 4..7)
  end

  defp discord_id_unique_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:discord_id, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end
end
