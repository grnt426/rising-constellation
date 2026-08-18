defmodule RC.Discord.PlayerCard do
  @moduledoc """
  Assembles the data for the `/player` profile card.

  This is the privacy boundary for the command: the card gets game
  stats and profile flavor only — never email, Discord/Steam ids, or
  any other account field. Rendering happens only when the owning
  account has opted in via `show_profile_in_discord`.
  """

  require Logger

  alias RC.Accounts

  @avatar_pattern ~r/^avatar[MF]_\d{3}\.jpg$/

  @doc """
  `{:ok, card_data}` ready for `RC.Discord.Render.Cards.player_profile/1`,
  `{:error, :not_found}` for unknown usernames, or `{:error, :hidden}`
  when the player hasn't opted in.
  """
  def for_username(username) when is_binary(username) do
    case Accounts.get_profile_by_name(String.trim(username)) do
      nil ->
        {:error, :not_found}

      profile ->
        if profile.account && profile.account.show_profile_in_discord do
          {:ok, assemble(profile)}
        else
          # Hidden and shown share no card, but the reply may say the
          # player exists — profile names are already public in-game.
          {:error, :hidden}
        end
    end
  end

  def for_username(_), do: {:error, :not_found}

  defp assemble(profile) do
    %{
      name: profile.name,
      full_name: profile.full_name,
      description: profile.description,
      avatar_jpeg: read_avatar(profile.avatar),
      favorite_faction: profile.favorite_faction,
      favorite_icon: profile.favorite_icon,
      stats: RC.ProfileStats.for_profile(profile.id)
    }
  end

  # profiles.avatar is a bare filename, but it's a free string at the DB
  # level (old seeds hold "todo") — allow-list the known shape instead of
  # trusting it as a path component.
  defp read_avatar(avatar) when is_binary(avatar) do
    if Regex.match?(@avatar_pattern, avatar) do
      path = Path.join([to_string(:code.priv_dir(:rc)), "data/avatars", avatar])

      case File.read(path) do
        {:ok, jpeg} ->
          jpeg

        {:error, reason} ->
          Logger.warning("[RC.Discord.PlayerCard] avatar #{avatar} unreadable: #{inspect(reason)}")
          nil
      end
    else
      nil
    end
  end

  defp read_avatar(_), do: nil
end
