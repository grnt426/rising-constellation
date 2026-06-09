defmodule RC.Discord.PlayerLookup do
  @moduledoc """
  Resolves "this Discord user is currently playing as which game
  profile, in which instance, in which faction?" for slash commands
  that operate on a linked player's in-game state.

  The contract is intentionally narrow:

    * `for_discord_id/1` returns `{:ok, context}` when exactly one
      profile of the linked account is in a `"playing"` registration
      (i.e., the game has started and they haven't been killed or
      resigned).
    * `{:error, :not_linked}` — the Discord user hasn't run `/link`.
    * `{:error, :no_active_game}` — linked, but no playing
      registration. Use during pre-game (state `"joined"`) returns
      this too, by design — fleet / agent queries make no sense
      before the game starts.
    * `{:error, {:multiple_active_games, [instance_id, ...]}}` —
      more than one profile playing simultaneously. The caller can
      offer a picker; for v0 we just surface a friendly error.

  Used by `/system`, `/fleets`, `/agents`. Not used by `/standings`
  (which doesn't require instance scoping).
  """

  import Ecto.Query

  alias RC.Accounts.Account
  alias RC.Accounts.Discord, as: DiscordLink
  alias RC.Accounts.Profile
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
    # Join through to filter by account, but preload separately so
    # the structs come back fully populated for downstream use.
    regs =
      from(r in Registration,
        join: p in assoc(r, :profile),
        where: p.account_id == ^account_id,
        where: r.state == "playing",
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
