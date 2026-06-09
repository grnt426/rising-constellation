defmodule RC.Discord.PlayerLookup do
  @moduledoc """
  Resolves "this Discord user is currently playing as which game
  profile, in which **promoted** instance, in which faction?" for
  slash commands that operate on a linked player's in-game state.

  ## Scope: promoted + live only

  Only registrations in instances that have a `discord_matches` row
  (i.e., were promoted via `/promote legacy`) AND whose state is
  `running` or `paused` are considered. This is a deliberate
  narrowing — the bot exists to support community-wide Discord
  matches, so its slash queries shouldn't surface side-projects or
  bot stress-test games that happen to be on the box. With this
  filter, `:multiple_active_games` becomes essentially impossible
  in normal operation (we don't run multiple promoted Legacy
  matches concurrently).

  ## Returns

    * `{:ok, context}` — exactly one promoted+live registration
      found.
    * `{:error, :not_linked}` — Discord user hasn't run `/link`.
    * `{:error, :no_active_game}` — linked, but no registration in
      a promoted+live instance. Pre-game (state `joined`,
      instance in `open`) returns this too — fleet / agent queries
      have nothing to read before the game starts.
    * `{:error, {:multiple_active_games, [instance_id, ...]}}` —
      defensive case; surfaces a friendly error and lets the operator
      decide how to disambiguate.

  Used by `/system`, `/fleets`, `/agents`. Not used by `/standings`
  (community-wide, not instance-scoped).
  """

  import Ecto.Query

  alias RC.Accounts.Account
  alias RC.Accounts.Discord, as: DiscordLink
  alias RC.Accounts.Profile
  alias RC.Discord.Match
  alias RC.Instances.Faction
  alias RC.Instances.Instance
  alias RC.Instances.Registration
  alias RC.Repo

  @type context :: %{
          account: Account.t(),
          profile: Profile.t(),
          registration: Registration.t(),
          faction: Faction.t(),
          instance: Instance.t()
        }

  @doc """
  Resolve the player context for a Discord user id.
  """
  @spec for_discord_id(String.t() | integer()) ::
          {:ok, context}
          | {:error,
             :not_linked
             | :no_active_game
             | {:multiple_active_games, [integer()]}}
  def for_discord_id(discord_id) when is_binary(discord_id) or is_integer(discord_id) do
    case DiscordLink.get_account_by_discord_id(to_string(discord_id)) do
      nil ->
        {:error, :not_linked}

      %Account{} = account ->
        for_account(account)
    end
  end

  defp for_account(%Account{id: account_id} = account) do
    # Filter to registrations that are:
    #   - in "playing" state (alive and active),
    #   - whose instance is in a live state ("running" or "paused"),
    #   - whose instance has a discord_matches row (i.e., was
    #     promoted via /promote legacy).
    # Joining `Match` via on: m.instance_id == i.id is what gates
    # "promoted only" — without a match row, the registration is
    # filtered out.
    regs =
      from(r in Registration,
        join: p in assoc(r, :profile),
        join: f in assoc(r, :faction),
        join: i in assoc(f, :instance),
        join: m in Match,
        on: m.instance_id == i.id,
        where: p.account_id == ^account_id,
        where: r.state == "playing",
        where: i.state in ["running", "paused"],
        preload: [:profile, faction: :instance]
      )
      |> Repo.all()

    case regs do
      [] ->
        {:error, :no_active_game}

      [reg] ->
        {:ok, build_context(account, reg)}

      many ->
        ids = Enum.map(many, & &1.faction.instance_id)
        {:error, {:multiple_active_games, ids}}
    end
  end

  defp build_context(account, %Registration{} = reg) do
    %{
      account: account,
      profile: reg.profile,
      registration: reg,
      faction: reg.faction,
      instance: reg.faction.instance
    }
  end
end
