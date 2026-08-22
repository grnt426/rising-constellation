defmodule RC.Discord.GovRelay do
  @moduledoc """
  Faction-government news for Discord: election lifecycle blasts in
  the match-feed channel (community guild), plus leadership role
  assignment.

  `Instance.Faction.Agent` forwards a curated set of government events
  here (see `@ceremony_events` — leadership positions and the
  ceremony/processes around them only; patents, lexes, taxes, policy
  churn are deliberately NOT broadcast). Casting to the unregistered
  name (bot off, :test) is a silent no-op.

  ## Seat holders and roles

  When a leadership seat changes hands the relay reconciles the
  matching Discord role (`@seat_role_names`, looked up by name on the
  community guild and created on demand — the ids on the retired
  Legacy guild died with it): the displaced holder loses it, the new
  holder gains it — both only when the player has linked their Discord
  account. Seat announcements for linked players append their Discord
  display name in plain text (never an @-mention).
  """

  use GenServer

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Nostrum.Api.Guild, as: NostrumGuild
  alias Nostrum.Api.Message
  alias RC.Accounts.Account
  alias RC.Accounts.Profile
  alias RC.Discord.News
  alias RC.Repo

  # Government seats that carry a Discord role + announcements.
  @leadership_seats [:leader, :economy, :military]

  # Seat → role NAME on the community guild (same names the retired
  # Legacy guild used). Looked up case-insensitively per event and
  # created on demand when missing — hardcoded snowflakes died with
  # the old guild, and name-based lookup survives a server rebuild.
  @seat_role_names %{
    leader: "faction-leader",
    economy: "cabinet-econ",
    military: "cabinet-military"
  }

  # Event types the faction agent forwards. Everything else in the
  # government engine stays off Discord.
  @ceremony_events [
    :elections_opened,
    :seat_changed,
    :election_failed,
    :revote_opened,
    :seat_incapacitated,
    :deposition_started,
    :deposed,
    :government_dissolved,
    :cabinet_dissolved,
    :crisis_vote_started,
    :challenge_started,
    :challenge_defended,
    :government_overthrown
  ]

  # --- Public API ------------------------------------------------------

  @doc "Event types worth forwarding from the faction agent."
  def ceremony_events, do: @ceremony_events

  @doc """
  Fire-and-forget relay from the faction agent. The agent forwards
  EVERY settled government event; the ceremony filter lives here (one
  source of truth next to `render/2`) and non-ceremony events return
  without casting. A cast to the unregistered name (bot disabled,
  :test) is a silent no-op.
  """
  def post_async(instance_id, faction_key, event) do
    if is_map(event) and Map.get(event, :type) in @ceremony_events do
      GenServer.cast(__MODULE__, {:gov_event, instance_id, faction_key, event})
    end

    :ok
  end

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:gov_event, instance_id, faction_key, event}, state) do
    case RC.Instances.get_instance(instance_id) do
      %{discord_ready: true, name: instance_name} ->
        # Resolve the seated/displaced players' Discord identities once
        # per event — role sync and the announcement decoration share it.
        identities = seat_identities(event)
        sync_roles(event, identities)

        event = decorate_seated(event, identities)

        case render(faction_key, event) do
          nil -> :ok
          message -> post("🗳️ **#{instance_name}**: #{message}", instance_id)
        end

      _ ->
        :ok
    end

    {:noreply, state}
  rescue
    e ->
      Logger.warning("[RC.Discord.GovRelay] gov event handling crashed: #{inspect(e)}")
      {:noreply, state}
  end

  # --- Rendering (pure; unit-tested without the bot) -------------------

  @doc """
  One short sentence for a government event, or nil for events that
  don't broadcast (non-leadership seats, plain vacancies). Keep these
  short and sweet, and free of em-dashes (user rule).
  """
  def render(faction_key, event)

  def render(faction_key, %{type: :elections_opened} = event) do
    seats =
      (event[:seats] || [])
      |> Enum.filter(&(&1 in @leadership_seats))

    case seats do
      [] ->
        nil

      seats ->
        "Elections have opened for #{faction(faction_key)}: #{Enum.map_join(seats, ", ", &seat_name/1)}."
    end
  end

  def render(faction_key, %{type: :seat_changed, seat: seat, player_id: player_id} = event)
      when seat in @leadership_seats and not is_nil(player_id) do
    who = event[:who_display] || event[:name] || "A new holder"
    "#{who} is now the #{seat_name(seat)} of #{faction(faction_key)}."
  end

  def render(faction_key, %{type: :election_failed, seat: seat})
      when seat in @leadership_seats do
    "The #{seat_name(seat)} election for #{faction(faction_key)} has failed. The seat stays open."
  end

  def render(faction_key, %{type: :revote_opened, seat: seat} = event)
      when seat in @leadership_seats do
    round_note = if event[:round], do: " (round #{event[:round]})", else: ""
    "A new vote for the #{seat_name(seat)} of #{faction(faction_key)} has opened#{round_note}."
  end

  def render(faction_key, %{type: :seat_incapacitated, seat: seat} = event)
      when seat in @leadership_seats do
    who = event[:name] || "The holder"
    "#{who} no longer holds the #{seat_name(seat)} seat of #{faction(faction_key)}."
  end

  def render(faction_key, %{type: :deposition_started, seat: seat})
      when seat in @leadership_seats do
    "A vote to depose the #{seat_name(seat)} of #{faction(faction_key)} has begun."
  end

  def render(faction_key, %{type: :deposed, seat: seat} = event)
      when seat in @leadership_seats do
    who = event[:name] || "The holder"
    "#{who} has been deposed as the #{seat_name(seat)} of #{faction(faction_key)}."
  end

  def render(faction_key, %{type: :government_dissolved}),
    do: "The government of #{faction(faction_key)} has been dissolved."

  def render(faction_key, %{type: :cabinet_dissolved}),
    do: "The cabinet of #{faction(faction_key)} has been dissolved."

  def render(faction_key, %{type: :crisis_vote_started}),
    do: "A crisis vote against the leadership of #{faction(faction_key)} has begun."

  def render(faction_key, %{type: :challenge_started} = event) do
    who = event[:name] || "A challenger"
    "#{who} has launched a challenge for the leadership of #{faction(faction_key)}."
  end

  def render(faction_key, %{type: :challenge_defended}) do
    "The leadership of #{faction(faction_key)} has defended its position. The challenge failed."
  end

  def render(faction_key, %{type: :government_overthrown} = event) do
    who = event[:name] || "A challenger"
    "#{who} has overthrown the government of #{faction(faction_key)}."
  end

  def render(_faction_key, _event), do: nil

  defp faction(key), do: News.faction_display(to_string(key))

  defp seat_name(:leader), do: "Leader"
  defp seat_name(:economy), do: "Head of Economy"
  defp seat_name(:military), do: "Head of Military"
  defp seat_name(other), do: other |> to_string() |> String.capitalize()

  # --- Seat identity resolution ----------------------------------------

  # One DB lookup per involved player per event: %{new: discord_id |
  # nil, prev: discord_id | nil}. Only seat_changed events on
  # leadership seats involve identities.
  defp seat_identities(%{type: :seat_changed, seat: seat} = event)
       when seat in @leadership_seats do
    %{
      new: event |> Map.get(:player_id) |> discord_id_for_profile(),
      prev: event |> Map.get(:previous) |> holder_id() |> discord_id_for_profile()
    }
  end

  defp seat_identities(_event), do: %{new: nil, prev: nil}

  # For a freshly seated player with a linked Discord account, append
  # their Discord display name in plain text ("Nova (Discord: kurtz)").
  # Never an @-mention (user rule).
  defp decorate_seated(%{type: :seat_changed, seat: seat, player_id: player_id, name: name} = event, %{
         new: discord_id
       })
       when seat in @leadership_seats and not is_nil(player_id) and not is_nil(discord_id) do
    who =
      case member_display_name(discord_id) do
        nil -> name
        display -> "#{name} (Discord: #{display})"
      end

    Map.put(event, :who_display, who)
  end

  defp decorate_seated(event, _identities), do: event

  # --- Leadership role sync --------------------------------------------

  defp sync_roles(%{type: :seat_changed, seat: seat} = event, identities)
       when seat in @leadership_seats do
    with guild_id when not is_nil(guild_id) <- RC.Discord.community_guild_id(),
         role_id when not is_nil(role_id) <- ensure_seat_role(guild_id, seat) do
      same_player? =
        Map.get(event, :player_id) != nil and
          Map.get(event, :player_id) == event |> Map.get(:previous) |> holder_id()

      if identities.prev != nil and not same_player? do
        change_role(:remove, guild_id, identities.prev, role_id, seat)
      end

      if identities.new != nil do
        change_role(:add, guild_id, identities.new, role_id, seat)
      end

      :ok
    else
      _ -> :ok
    end
  end

  defp sync_roles(_event, _identities), do: :ok

  # Resolve the seat's role id by name on the community guild,
  # creating it if this is the first seat event since the server
  # started fresh. Returns nil (sync skipped, announcement still
  # posts) when the guild is unreadable or creation fails.
  defp ensure_seat_role(guild_id, seat) do
    role_name = Map.fetch!(@seat_role_names, seat)

    case NostrumGuild.roles(guild_id) do
      {:ok, roles} ->
        existing =
          Enum.find(roles, fn role ->
            String.downcase(role.name) == String.downcase(role_name)
          end)

        case existing do
          %{id: id} ->
            id

          nil ->
            case NostrumGuild.create_role(
                   guild_id,
                   %{name: role_name, permissions: 0, hoist: false, mentionable: false},
                   "leadership seat role (created on demand)"
                 ) do
              {:ok, role} ->
                Logger.warning("[RC.Discord.GovRelay] created seat role '#{role_name}' (#{role.id})")
                role.id

              {:error, reason} ->
                Logger.warning("[RC.Discord.GovRelay] create seat role '#{role_name}' failed: #{inspect(reason)}")

                nil
            end
        end

      {:error, reason} ->
        Logger.warning("[RC.Discord.GovRelay] could not fetch guild roles: #{inspect(reason)}")
        nil
    end
  end

  defp holder_id(%{player_id: id}), do: id
  defp holder_id(_), do: nil

  defp change_role(op, guild_id, discord_id, role_id, seat) do
    user_id = String.to_integer(to_string(discord_id))

    result =
      case op do
        :add -> NostrumGuild.add_member_role(guild_id, user_id, role_id)
        :remove -> NostrumGuild.remove_member_role(guild_id, user_id, role_id)
      end

    case result do
      {:ok} ->
        Logger.info("[RC.Discord.GovRelay] #{op} #{seat} role for #{discord_id}")

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[RC.Discord.GovRelay] #{op} #{seat} role failed for #{discord_id}: " <>
            RC.Discord.format_api_error(reason)
        )
    end
  end

  # --- Identity plumbing -----------------------------------------------

  # Government player_ids are profile ids; a profile hangs off an
  # account, which may carry a Discord link. Single joined query.
  defp discord_id_for_profile(nil), do: nil

  defp discord_id_for_profile(profile_id) do
    from(p in Profile,
      join: a in Account,
      on: a.id == p.account_id,
      where: p.id == ^profile_id,
      select: a.discord_id
    )
    |> Repo.one()
  end

  defp member_display_name(discord_id) do
    with guild_id when not is_nil(guild_id) <- RC.Discord.community_guild_id(),
         {:ok, member} <- NostrumGuild.member(guild_id, String.to_integer(to_string(discord_id))) do
      user = Map.get(member, :user) || %{}

      Map.get(member, :nick) || Map.get(user, :global_name) || Map.get(user, :username)
    else
      _ -> nil
    end
  end

  defp post(content, instance_id) do
    case RC.Discord.news_channel_id() do
      nil ->
        :ok

      channel_id ->
        case Message.create(channel_id, %{content: content}) do
          {:ok, _msg} ->
            :ok

          {:error, reason} ->
            Logger.warning("[RC.Discord.GovRelay] post failed (instance ##{instance_id}): #{inspect(reason)}")
        end
    end
  end
end
