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

  ## Votes, in the faction's own channel

  The match feed is public; a faction's votes are its own business. In
  an official match that was promoted to Discord (`/promote legacy`),
  every ballot that opens and every result is posted to that faction's
  private `#general` channel instead (`votes_async/4`): the members who
  have to vote hear of it where they talk, in the faction's own seat
  titles. A match with no promoted channels posts nothing.
  """

  use GenServer

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Nostrum.Api.Guild, as: NostrumGuild
  alias Nostrum.Api.Message
  alias RC.Accounts.Account
  alias RC.Accounts.Profile
  alias RC.Discord.Match
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

  # The per-faction channel that hears of votes: one of the six channels
  # RC.Discord.LegacyMatch creates under each faction's category.
  @votes_channel "general"

  # Seat titles as each faction's players read them in game (mirrors
  # `panel.faction_government.seat_names` in the client's game.json).
  @seat_titles %{
    "tetrarchy" => %{leader: "Tetrarch", economy: "Quaestor", military: "Strategos"},
    "myrmezir" => %{leader: "President", economy: "Economic Advisor", military: "Department of Defense"},
    "synelle" => %{leader: "President", economy: "Interior Ministry", military: "Foreign Affairs"},
    "ark" => %{leader: "Executive", economy: "Board of Commerce", military: "Industrial Arms Overseer"},
    "cardan" => %{
      leader: "Eminence",
      economy: "Circle of the Golden Palm",
      military: "Circle of the Iron Palm"
    }
  }

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

  @doc """
  Fire-and-forget notice for the faction's own Discord channel: the
  ballots that just opened (`:opened`, maps of `seat`, `question`,
  `kind`, `candidates`, `target`, `closes_at`) or just closed (`:closed`,
  the engine's `:ballot_closed` events). One message per call.
  """
  def votes_async(instance_id, faction_key, phase, ballots)
      when phase in [:opened, :closed] and is_list(ballots) do
    if ballots != [] do
      GenServer.cast(__MODULE__, {:faction_votes, instance_id, faction_key, phase, ballots})
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

  def handle_cast({:faction_votes, instance_id, faction_key, phase, ballots}, state) do
    with %{discord_ready: true} <- RC.Instances.get_instance(instance_id),
         content when is_binary(content) <- render_votes(faction_key, phase, ballots),
         {channel_id, state} when not is_nil(channel_id) <- votes_channel(state, instance_id, faction_key) do
      {:noreply, post_votes(state, channel_id, content, {instance_id, faction_key})}
    else
      {nil, state} -> {:noreply, state}
      _ -> {:noreply, state}
    end
  rescue
    e ->
      Logger.warning("[RC.Discord.GovRelay] vote notice crashed: #{inspect(e)}")
      {:noreply, state}
  end

  # --- Rendering (pure; unit-tested without the bot) -------------------

  @doc """
  The message for a batch of ballots that opened or closed, written for
  the faction's own channel, or nil when there is nothing to say. Same
  house rules as `render/2`: short, no em-dashes, no mentions.
  """
  def render_votes(_faction_key, _phase, []), do: nil

  def render_votes(faction_key, :opened, ballots) do
    lines = Enum.map(ballots, &opened_line(faction_key, &1))

    closes =
      case ballots |> Enum.map(&Map.get(&1, :closes_at)) |> Enum.filter(&is_integer/1) do
        [] -> ""
        times -> "Voting closes <t:#{Enum.min(times)}:R>. "
      end

    footer = closes <> "Vote or abstain in game."

    case lines do
      [line] -> "🗳️ A vote has opened. #{line} #{footer}"
      lines -> "🗳️ Votes have opened.\n" <> bullets(lines) <> "\n" <> footer
    end
  end

  def render_votes(faction_key, :closed, ballots) do
    case Enum.map(ballots, &closed_line(faction_key, &1)) do
      [line] -> "🗳️ A vote has closed. #{line}"
      lines -> "🗳️ Votes have closed.\n" <> bullets(lines)
    end
  end

  defp bullets(lines), do: Enum.map_join(lines, "\n", &("- " <> &1))

  defp opened_line(faction_key, %{question: :approve} = ballot),
    do: "#{seat_title(faction_key, ballot)}: confirmation of #{subject(ballot)}."

  defp opened_line(faction_key, %{question: :depose} = ballot),
    do: "#{seat_title(faction_key, ballot)}: vote to depose #{subject(ballot)}."

  defp opened_line(faction_key, %{question: :dissolve} = ballot),
    do: "#{seat_title(faction_key, ballot)}: crisis vote to remove #{subject(ballot)}."

  defp opened_line(faction_key, %{question: :laws} = ballot) do
    who =
      case Map.get(ballot, :proposed_by) do
        name when is_binary(name) -> name
        _ -> "The leadership"
      end

    laws = Map.get(ballot, :laws) || %{}

    change =
      case {law_names(Map.get(laws, :enact)), law_names(Map.get(laws, :repeal))} do
        {nil, nil} -> "change the laws"
        {enact, nil} -> "enact #{enact}"
        {nil, repeal} -> "repeal #{repeal}"
        {enact, repeal} -> "enact #{enact} and repeal #{repeal}"
      end

    "#{seat_title(faction_key, ballot)}: #{who} proposes to #{change}."
  end

  defp opened_line(faction_key, ballot) do
    what =
      case Map.get(ballot, :kind) do
        :stake_bid -> "auction"
        :stake_pledge -> "tithe offering"
        _ -> "election"
      end

    "#{seat_title(faction_key, ballot)}: #{what}.#{candidacy(ballot)}"
  end

  # A seat that just opened has nobody on its ballot yet, except where
  # the rules put them there (Tetrarchy lists its top-ranked members):
  # say who is on it, or how a member gets on it.
  defp candidacy(ballot) do
    case {Map.get(ballot, :candidates) || [], Map.get(ballot, :open_candidacy)} do
      {[_ | _] = names, _} -> " On the ballot: #{Enum.join(names, ", ")}."
      {[], :self_only} -> " Any member can stand."
      {[], :others_only} -> " Members nominate one another."
      {[], :anyone} -> " Any member can stand or be nominated."
      {[], :by_stake} -> " Bid on any member to put them forward."
      _ -> ""
    end
  end

  # Law keys read well enough as names ("war_footing" -> "War Footing");
  # the game's own names live in the client's locale files.
  defp law_names(nil), do: nil
  defp law_names([]), do: nil

  defp law_names(keys) do
    Enum.map_join(keys, ", ", fn key ->
      key |> to_string() |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)
    end)
  end

  defp closed_line(faction_key, %{question: :approve, outcome: outcome} = ballot) do
    verdict = if outcome == :approved, do: "is confirmed", else: "is rejected"
    "#{seat_title(faction_key, ballot)}: #{subject(ballot)} #{verdict}."
  end

  # A deposition passes as an approval, or (Cardan's loss of faith) as a
  # pledge that reached its quorum.
  defp closed_line(faction_key, %{question: :depose, outcome: outcome} = ballot) do
    verdict = if outcome in [:approved, :seated], do: "is deposed", else: "keeps the seat"
    "#{seat_title(faction_key, ballot)}: #{subject(ballot)} #{verdict}."
  end

  defp closed_line(faction_key, %{question: :dissolve, outcome: outcome} = ballot) do
    verdict = if outcome == :approved, do: "passed, the leadership falls", else: "failed"
    "#{seat_title(faction_key, ballot)}: the crisis vote #{verdict}."
  end

  defp closed_line(faction_key, %{question: :laws, outcome: outcome} = ballot) do
    verdict = if outcome == :approved, do: "adopted", else: "rejected"
    "#{seat_title(faction_key, ballot)}: the change of laws is #{verdict}."
  end

  defp closed_line(faction_key, %{outcome: :seated} = ballot) do
    who =
      case Map.get(ballot, :winner) do
        %{name: name} -> name
        _ -> "A member"
      end

    "#{seat_title(faction_key, ballot)}: #{who} wins the seat."
  end

  defp closed_line(faction_key, ballot) do
    why =
      case Map.get(ballot, :outcome) do
        :no_candidates -> "nobody stood"
        :no_votes -> "no vote was cast"
        :quorum_not_met -> "the offering fell short"
        :quorum_rounds_exhausted -> "the vote was abandoned"
        _ -> "the vote failed"
      end

    "#{seat_title(faction_key, ballot)}: #{why}. No one is seated."
  end

  # Who a confirmation, a deposition or a crisis vote is about.
  defp subject(ballot) do
    case {Map.get(ballot, :target), Map.get(ballot, :candidates) || []} do
      {name, _} when is_binary(name) -> name
      {_, [name | _]} when is_binary(name) -> name
      _ -> "the holder"
    end
  end

  defp seat_title(_faction_key, %{seat: :laws}), do: "**Law referendum**"

  defp seat_title(faction_key, %{seat: seat}) do
    title = @seat_titles |> Map.get(to_string(faction_key), %{}) |> Map.get(seat)
    "**#{title || seat_name(seat)}**"
  end

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
        Logger.warning("[RC.Discord.GovRelay] #{op} #{seat} role failed for #{discord_id}: #{inspect(reason)}")
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

  # --- The faction's own channel ---------------------------------------

  # {channel_id | nil, state}. The match row only records each faction's
  # category, so the channel is found by name under it, once: the id is
  # kept until a post to it fails (a torn-down match).
  defp votes_channel(state, instance_id, faction_key) do
    cache = Map.get(state, :votes_channels, %{})
    key = {instance_id, faction_key}

    case Map.get(cache, key) do
      nil ->
        case find_votes_channel(instance_id, faction_key) do
          nil -> {nil, state}
          channel_id -> {channel_id, Map.put(state, :votes_channels, Map.put(cache, key, channel_id))}
        end

      channel_id ->
        {channel_id, state}
    end
  end

  defp find_votes_channel(instance_id, faction_key) do
    with %Match{faction_categories: categories} <- Repo.get_by(Match, instance_id: instance_id),
         category when is_binary(category) <- Map.get(categories || %{}, to_string(faction_key)),
         {category_id, ""} <- Integer.parse(category),
         guild_id when not is_nil(guild_id) <- RC.Discord.community_guild_id(),
         {:ok, channels} <- NostrumGuild.channels(guild_id),
         %{id: channel_id} <- Enum.find(channels, &votes_channel?(&1, category_id)) do
      channel_id
    else
      _ -> nil
    end
  end

  @doc false
  def votes_channel?(channel, category_id),
    do: Map.get(channel, :parent_id) == category_id and Map.get(channel, :name) == @votes_channel

  # Player names go out as plain text: nothing in a notice may ping.
  defp post_votes(state, channel_id, content, key) do
    case Message.create(channel_id, content: content, allowed_mentions: :none) do
      {:ok, _msg} ->
        state

      {:error, reason} ->
        Logger.warning("[RC.Discord.GovRelay] vote notice failed (#{inspect(key)}): #{inspect(reason)}")
        Map.put(state, :votes_channels, Map.delete(Map.get(state, :votes_channels, %{}), key))
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
