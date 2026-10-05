defmodule Instance.Faction.Faction do
  use TypedStruct
  use Util.MakeEnumerable

  alias Instance.Character.ActionQueue
  alias Instance.Faction
  alias Instance.Faction.Government
  alias Instance.Faction.Market
  alias Spatial
  alias Spatial.Disk
  alias Spatial.Position
  alias Instance.StellarSystem.StellarSystem

  # Interval between two 'ticks', mainly uses for radar checks
  # Unit is `game_days`.
  # Set on 3 days, meaning:
  # speed :fast -> every 4.5 seconds
  # speed :medium -> every 27 seconds
  # speed :long -> every 9 minutes
  @tick_interval 3
  @max_length_message 500

  # Each chat channel keeps its own ring, so chatter in General can never
  # push a claim or a sighting out of history. The whole chat rides every
  # `faction_faction` broadcast: keep the sum of these modest.
  @max_chat_messages 80
  @max_channel_messages 50

  # Sightings. The list is capped overall (oldest dropped: their chat
  # messages have left the ring by then), and so is the number of agent
  # sightings still being watched, since each costs a look at its system
  # on every tick.
  @max_sightings 60
  @max_live_agent_sightings 20
  # How far from the reported point a blip may be and still be the one
  # the player meant: their copy of the radar is up to one tick old.
  @blip_match_distance 5.0

  # Player-icon limits. Caps are per (placer, instance); rate limit is
  # per placer across the whole faction op stream. Both intentionally
  # tight enough that legitimate use never hits them while a flooding
  # client gets cut off quickly.
  @max_icons_per_player 50
  @icon_rate_limit_max 10
  @icon_rate_limit_window_ms 10_000

  def max_icons_per_player(), do: @max_icons_per_player

  # `icon_rate_buckets` is excluded from broadcasts — it's an internal
  # anti-flood counter, not state the client should see or render.
  # `galactic_survey_cache` is excluded too — it's a server-side TTL cache
  # that's pushed to clients on demand via `get_galactic_survey`, never
  # piggy-backed on the faction broadcast.
  def jason(),
    do: [
      except: [
        :instance_id,
        :all_radars,
        :icon_rate_buckets,
        :galactic_survey_cache,
        :chat_seq,
        :sighting_seq
      ]
    ]

  typedstruct enforce: true do
    field(:id, integer())
    field(:key, atom())
    field(:players, [%Faction.Player{}])
    field(:chat, [%Faction.ChatMessage{}])
    field(:contacts, %{})
    field(:all_radars, %{})
    field(:radars, %{})
    field(:detected_objects, [])
    field(:market_taxes, %Market{})
    field(:icons, [%Faction.SystemIcon{}])
    field(:icon_rate_buckets, %{integer() => [integer()]})
    field(:galactic_survey_cache, %Faction.GalacticSurvey{} | nil)
    # Faction government (Legacy-only; nil when disabled for this
    # instance's speed). Initialized lazily at the agent boundary — see
    # Faction.Agent.ensure_government/2 — so pre-feature snapshots
    # back-fill the same way fresh instances initialize.
    field(:government, %Government{} | nil)
    # Own diplomacy stance cache: %{other_faction_id => :war | :non_aggression}
    # (neutral absent). Pushed by Instance.Diplomacy.Agent on change;
    # Map.get access only (pre-feature snapshots restore without it).
    field(:diplomacy, map())
    field(:instance_id, integer())
    # Chat channels and sightings. Defaulted rather than enforced, and
    # back-filled by ensure_chat_fields/1: factions restored from an
    # older snapshot arrive without these keys.
    #
    # Next id to stamp on a chat message / a sighting.
    field(:chat_seq, integer(), default: 1)
    field(:sighting_seq, integer(), default: 1)
    # Enemy fleets and agents reported to the faction (see Faction.Sighting).
    field(:sightings, [%Faction.Sighting{}], default: [])
  end

  def new(faction, instance_id, icons \\ []) do
    %Faction.Faction{
      id: faction.id,
      key: String.to_existing_atom(faction.faction_ref),
      players: [],
      chat: [],
      contacts: %{},
      all_radars: %{},
      radars: %{},
      detected_objects: [],
      market_taxes: Market.new(),
      icons: Enum.map(icons, &Faction.SystemIcon.from_db/1),
      icon_rate_buckets: %{},
      galactic_survey_cache: nil,
      government: nil,
      diplomacy: %{},
      instance_id: instance_id
    }
    |> seed_chat()
  end

  # Floor for deadline-driven ticks: never busy-loop the agent even if a
  # government deadline sits (or lands) very close to now.
  @min_tick_interval 0.05

  def compute_next_tick_interval(state) do
    base = @tick_interval + :rand.uniform(200) / 1000

    # Wake up ON the next government deadline (election close, founding
    # end, term expiry) when it lands before the regular tick — Map.get
    # because pre-government snapshots restore without the field.
    case Map.get(state, :government) do
      nil ->
        base

      government ->
        case Government.next_deadline(government) do
          nil -> base
          deadline -> max(min(base, deadline), @min_tick_interval)
        end
    end
  end

  # Action handling

  def add_player(state, player) do
    %{state | players: [Faction.Player.convert(player) | state.players]}
  end

  def get_player_name(state, player_id) do
    player = Enum.find(state.players, fn player -> player.id == player_id end)

    unless is_nil(player),
      do: player.name,
      else: "unknown player"
  end

  def get_system_contact(state, system_id) do
    Map.get(state.contacts, system_id, Core.VisibilityValue.new())
  end

  def drop_system_explorer(state, system_id, player_name) do
    contact = Map.get(state.contacts, system_id, Core.VisibilityValue.new())

    {response, contact} =
      if Map.has_key?(contact.details, :explorer) do
        {:already_dropped, contact}
      else
        {:dropped, Core.VisibilityValue.add(contact, :explorer, Core.ValuePart.new(player_name, 1))}
      end

    state = %{state | contacts: Map.put(state.contacts, system_id, contact)}
    {response, contact, state}
  end

  def drop_system_informer(state, _player_name, _system_id, 0),
    do: {MapSet.new(), nil, state}

  def drop_system_informer(state, system_id, player_name, count) do
    contact = Map.get(state.contacts, system_id, Core.VisibilityValue.new())

    contact =
      Enum.reduce(1..count, contact, fn _i, acc ->
        Core.VisibilityValue.add(acc, :informer, Core.ValuePart.new(player_name, 1))
      end)

    state = %{state | contacts: Map.put(state.contacts, system_id, contact)}
    state = %{state | radars: filter_radar_by_visibility(state)}

    {MapSet.new([:dropped, :radar_update]), contact, state}
  end

  def remove_informer(state, system_id) do
    contact =
      state
      |> get_system_contact(system_id)
      |> Core.VisibilityValue.remove(:informer)

    state = %{state | contacts: Map.put(state.contacts, system_id, contact)}
    state = %{state | radars: filter_radar_by_visibility(state)}

    {MapSet.new([:radar_update]), state}
  end

  def resolve_system_visibility(state, system) do
    contact = get_system_contact(state, system.id)

    contact =
      if Enum.any?(system.characters, fn c -> c.owner.faction == state.key end),
        do: Core.VisibilityValue.apply_minimum(contact, Core.ValuePart.new(:agent_on_system, 2)),
        else: contact

    contact =
      if system.owner != nil and system.owner.faction == state.key,
        do: Core.VisibilityValue.apply_minimum(contact, Core.ValuePart.new(:own_faction, 5)),
        else: contact

    apply_diplomacy_modifier(contact, state, system)
  end

  # Diplomacy teeth (the modifiers the original TODO planned for): a
  # declared war fogs enemy systems (−1 contact), a non-aggression pact
  # opens the borders a crack (+1). Applied to the RESOLVED value only —
  # the stored contact (informers, explorers) is untouched, so stance
  # changes take effect and revert instantly.
  defp apply_diplomacy_modifier(contact, state, system) do
    cond do
      system.owner == nil ->
        contact

      system.owner.faction == state.key ->
        contact

      true ->
        case Map.get(Map.get(state, :diplomacy) || %{}, system.owner.faction_id) do
          :war -> %{contact | value: max(contact.value - 1, 0)}
          :non_aggression -> %{contact | value: min(contact.value + 1, 5)}
          _ -> contact
        end
    end
  end

  def resolve_character_visibility(state, system, character) do
    contact = resolve_system_visibility(state, system)

    if character.owner.faction == state.key,
      do: 5,
      else: contact.value
  end

  # Defense-in-depth guards: even though the agent's on_cast already
  # validates shape, a future caller mistake here used to crash the
  # entire Faction.Agent (`String.length(nil)` raised → per-faction DoS).
  # Reject anything that isn't a binary / integer instead.
  #
  # `channel` is one of Faction.ChatMessage.channels/0; anything else
  # lands in the default channel (the channel boundary already rejects
  # unknown ones with a visible error).
  def push_message(state, from, from_id, message, channel \\ Faction.ChatMessage.default_channel())

  def push_message(state, from, from_id, message, channel)
      when is_binary(from) and is_integer(from_id) and is_binary(message) do
    message =
      if String.length(message) > @max_length_message,
        do: String.slice(message, 0..@max_length_message) <> " [...]",
        else: message

    {_message, state} =
      append_chat_message(state, Faction.ChatMessage.new(from, from_id, message, channel: channel))

    state
  end

  def push_message(state, _from, _from_id, _message, _channel), do: state

  # Server-originated chat line (nil from_id is the client's "system" marker
  # — real senders always carry their JWT-bound profile id, and a nil
  # from_id is never muteable client-side).
  def push_system_message(state, message) when is_binary(message) do
    {_message, state} = append_chat_message(state, Faction.ChatMessage.new("SYSTEM", nil, message))
    state
  end

  # The post the game makes for a player who plants a claim flag on a
  # system. The body is a plain system chip, so it reads correctly even
  # for a client that knows nothing of `meta`; `meta` is what lets the
  # client word it as a claim, strike it once the flag is gone, and find
  # it again from the flag on the map.
  def push_claim(state, from, from_id, system_id)
      when is_binary(from) and is_integer(from_id) and is_integer(system_id) do
    message =
      Faction.ChatMessage.new(from, from_id, "[[sys:#{system_id}]]",
        channel: "claims",
        meta: %{"kind" => "claim", "system_id" => system_id}
      )

    {_message, state} = append_chat_message(state, message)
    state
  end

  def push_claim(state, _from, _from_id, _system_id), do: state

  # Factions restored from a snapshot taken before chat channels existed
  # carry messages with no :id / :channel / :meta and no sequence
  # counters. Number the ring in place (it is ordered oldest first) and
  # file everything under the default channel. Cheap no-op afterwards.
  def ensure_chat_fields(state) do
    state =
      if Map.has_key?(state, :chat_seq),
        do: state,
        else: number_chat(state)

    state
    |> Map.put_new(:sighting_seq, 1)
    |> Map.put_new(:sightings, [])
  end

  defp number_chat(state) do
    {chat, next_id} =
      state
      |> Map.get(:chat, [])
      |> Enum.map_reduce(1, fn message, id ->
        message =
          message
          |> Map.put(:id, id)
          |> Map.put_new(:channel, Faction.ChatMessage.default_channel())
          |> Map.put_new(:meta, nil)

        {message, id + 1}
      end)

    state
    |> Map.put(:chat, chat)
    |> Map.put(:chat_seq, next_id)
  end

  # Returns `{stamped_message, state}`: callers that need to point at the
  # message later (sightings) read its id from the first element.
  defp append_chat_message(state, %Faction.ChatMessage{} = message) do
    state = ensure_chat_fields(state)
    message = %{message | id: state.chat_seq}
    chat = trim_channel(state.chat ++ [message], message.channel)

    {message, %{state | chat: chat, chat_seq: state.chat_seq + 1}}
  end

  # Drop the oldest messages of `channel` beyond its cap; other channels
  # are left alone.
  defp trim_channel(chat, channel) do
    cap =
      if channel == Faction.ChatMessage.default_channel(),
        do: @max_chat_messages,
        else: @max_channel_messages

    excess = Enum.count(chat, &(&1.channel == channel)) - cap

    if excess > 0 do
      {kept, _left} =
        Enum.flat_map_reduce(chat, excess, fn message, left ->
          if left > 0 and message.channel == channel,
            do: {[], left - 1},
            else: {[message], left}
        end)

      kept
    else
      chat
    end
  end

  # Cheat-enabled games announce themselves in every faction's chat from
  # the very first join. Seeded at genesis (Faction.new runs after the
  # metadata cache is populated in Instance.Manager.init_from_model).
  defp seed_chat(state) do
    if Instance.Cheats.enabled?(state.instance_id),
      do: push_system_message(state, Instance.Cheats.chat_announcement()),
      else: state
  end

  def radar_update(%{all_radars: all_radars} = state, %StellarSystem{} = system) do
    all_radars =
      if system.radar.value <= 0 or is_nil(system.owner) do
        Map.delete(all_radars, system.id)
      else
        c = Data.Querier.one(Data.Game.Constant, state.instance_id, :main)

        new_radar = %{
          faction_id: system.owner.faction_id,
          disk: %Disk{
            x: system.position.x,
            y: system.position.y,
            radius: system.radar.value * c.system_base_radar_size
          }
        }

        Map.update(all_radars, system.id, new_radar, fn _ -> new_radar end)
      end

    state = %{state | all_radars: all_radars}
    {:radar_update, %{state | radars: filter_radar_by_visibility(state)}}
  end

  # Tick handling

  def next_tick(state, elapsed_time) do
    {MapSet.new(), state}
    |> Market.lower_market_taxes(elapsed_time)
    |> Government.tick(elapsed_time)
    |> update_detected_object()
    |> update_sightings()
    |> detect_changes(state)
  end

  # Core functions

  defp update_detected_object({change, state}) do
    # TODO: filter les radars :
    # - si ma faction -> go
    # - si pas ma faction -> check visibility -> si 5 go

    characters_in_radar =
      state.radars
      |> Map.values()
      |> Task.async_stream(fn radar -> Spatial.nearby(radar.disk, state.instance_id) end)
      |> Stream.flat_map(fn {:ok, results} -> results end)
      |> Task.async_stream(
        fn {disk, found} ->
          # fetch the exact position of all nearby characters
          with "c-" <> character_id <- found,
               character_id <- String.to_integer(character_id),
               {:ok, _pid} <- Game.get_pid({state.instance_id, :character, character_id}),
               {:ok, {character, position, angle}} <-
                 Game.call(state.instance_id, :character, character_id, :get_position),
               # only keep characters visible to a radar
               true <- Position.in_disk(position, disk) do
            {disk, character, position, angle}
          else
            {:error, :process_not_found} ->
              Spatial.delete(found, state.instance_id)
              false

            _ ->
              false
          end
        end,
        on_timeout: :kill_task
      )
      |> Stream.filter(fn {atom, item} -> :ok == atom and item end)
      |> Stream.map(fn {:ok, val} -> val end)
      # only keep one of each object
      |> Stream.uniq_by(fn {_radar, character, _position, _angle} -> character.id end)
      # Internal blip shape: includes character_id (used by detect_changes/2
      # for "new object entered radar" detection, and to follow a reported
      # fleet), owner_player_id (used by
      # Portal.Controllers.FactionChannel.handle_out/3 to filter out the
      # viewer's own characters per-recipient) and the leg being flown.
      # The ids and `target_position` are stripped at the channel
      # boundary and never reach the wire; `target_system_id` does go out
      # (see the sanitize_for_viewer/2 path in faction_channel.ex).
      |> Stream.map(fn {_radar, character, position, angle} ->
        {target_system_id, target_position} = current_leg(character)

        %{
          faction: character.owner.faction,
          character_id: character.id,
          owner_player_id: character.owner.id,
          position: position,
          angle: angle,
          target_system_id: target_system_id,
          target_position: target_position
        }
      end)
      |> Enum.to_list()

    {change, %{state | detected_objects: characters_in_radar}}
  end

  # The jump a moving character is flying right now: its destination
  # system and that system's position. Only this leg, never the rest of
  # the queued route — the blip's position and heading already point
  # down it, which is why this much is shown to everyone.
  defp current_leg(character) do
    head =
      case ActionQueue.skip_initial_lock(Map.get(character, :actions)) do
        %ActionQueue{queue: queue} -> Queue.peek(queue)
        _ -> nil
      end

    case head do
      %{type: :jump, data: %{"target" => target} = data} when is_integer(target) ->
        {target, data["target_position"]}

      _ ->
        {nil, nil}
    end
  end

  # Sightings
  #
  # `report_fleet/5` and `report_agent/5` return
  # `{:ok, state, sighting, :created | :duplicate}` or `{:error, reason}`.
  # A thing that already has a live sighting is not reported twice: the
  # caller gets the existing one back, to show the player where it was
  # said.

  def report_fleet(state, reporter_id, reporter, %Position{} = position, faction)
      when is_integer(reporter_id) and is_binary(reporter) and is_binary(faction) do
    state = ensure_chat_fields(state)

    cond do
      rate_limited?(state, reporter_id) ->
        {:error, :report_rate_limited}

      true ->
        case nearest_foreign_blip(state, position, faction) do
          nil ->
            {:error, :contact_lost}

          blip ->
            open_sighting(state, blip.character_id, reporter_id, reporter, fn id, message_id ->
              Faction.Sighting.fleet(id, blip, reporter_id, message_id)
            end)
        end
    end
  end

  def report_fleet(_state, _reporter_id, _reporter, _position, _faction),
    do: {:error, :invalid_payload}

  # `system` is the system as this faction is allowed to see it (see
  # visible_system/2): an agent the faction cannot see there cannot be
  # reported, whatever id the client sends.
  def report_agent(state, reporter_id, reporter, system, character_id)
      when is_integer(reporter_id) and is_binary(reporter) and is_integer(character_id) do
    state = ensure_chat_fields(state)
    character = Enum.find(Map.get(system, :characters) || [], &(&1.id == character_id))

    cond do
      rate_limited?(state, reporter_id) ->
        {:error, :report_rate_limited}

      is_nil(character) or is_nil(character.owner) ->
        {:error, :agent_not_visible}

      character.owner.faction == state.key ->
        {:error, :own_faction_agent}

      true ->
        state
        |> retire_oldest_agent_sightings()
        |> open_sighting(character.id, reporter_id, reporter, fn id, message_id ->
          Faction.Sighting.agent(id, character, system, reporter_id, message_id)
        end)
    end
  end

  def report_agent(_state, _reporter_id, _reporter, _system, _character_id),
    do: {:error, :invalid_payload}

  # A system exactly as this faction's members get it from `get_system`:
  # same contact resolution, same obfuscation, so "visible" means one
  # thing everywhere.
  def visible_system(state, system_id) do
    case Game.call(state.instance_id, :stellar_system, system_id, :get_state) do
      {:ok, system} ->
        contact = resolve_system_visibility(state, system)
        {:ok, Faction.StellarSystem.obfuscate(system, contact, state.id, state.instance_id)}

      _ ->
        :error
    end
  end

  defp open_sighting(state, character_id, reporter_id, reporter, build) do
    case Enum.find(state.sightings, &(Faction.Sighting.live?(&1) and &1.character_id == character_id)) do
      %Faction.Sighting{} = existing ->
        {:ok, state, existing, :duplicate}

      nil ->
        id = state.sighting_seq

        message =
          Faction.ChatMessage.new(reporter, reporter_id, "[[spot:#{id}]]",
            channel: "spotted",
            meta: %{"kind" => "sighting", "sighting_id" => id}
          )

        {message, state} = append_chat_message(state, message)
        sighting = build.(id, message.id)

        state =
          %{state | sightings: Enum.take([sighting | state.sightings], @max_sightings), sighting_seq: id + 1}
          |> stamp_rate_bucket(reporter_id)

        {:ok, state, sighting, :created}
    end
  end

  # Make room for one more watched agent: beyond the cap, the oldest
  # ones stop being followed (the list is newest first).
  defp retire_oldest_agent_sightings(state) do
    {sightings, _kept} =
      Enum.map_reduce(state.sightings, 0, fn sighting, kept ->
        cond do
          not (Faction.Sighting.live?(sighting) and sighting.kind == "agent") -> {sighting, kept}
          kept < @max_live_agent_sightings - 1 -> {sighting, kept + 1}
          true -> {Faction.Sighting.lose(sighting, "untracked"), kept}
        end
      end)

    %{state | sightings: sightings}
  end

  defp nearest_foreign_blip(state, %Position{} = position, faction) do
    state.detected_objects
    |> Enum.filter(fn blip ->
      blip.faction != state.key and to_string(blip.faction) == faction and
        match?(%Position{}, blip.position) and
        Position.distance(blip.position, position) <= @blip_match_distance
    end)
    |> Enum.min_by(&Position.dist_squared(&1.position, position), fn -> nil end)
  end

  # Tick: confront every live sighting with what the faction can see now.
  defp update_sightings({change, state}) do
    backfilled? = not Map.has_key?(state, :chat_seq)
    state = ensure_chat_fields(state)

    # A faction restored from a pre-channel snapshot has just had its
    # chat numbered: every member needs the new ring.
    change = if backfilled?, do: MapSet.put(change, :chat_update), else: change

    if Enum.any?(state.sightings, &Faction.Sighting.live?/1) do
      systems = watched_systems(state)
      sightings = Enum.map(state.sightings, &refresh_sighting(&1, state, systems))

      if sightings == state.sightings,
        do: {change, state},
        else: {MapSet.put(change, :sightings_update), %{state | sightings: sightings}}
    else
      {change, state}
    end
  end

  # One look per system holding a watched agent, whatever the number of
  # agents reported there.
  defp watched_systems(state) do
    state.sightings
    |> Enum.filter(&(Faction.Sighting.live?(&1) and &1.kind == "agent"))
    |> Enum.map(& &1.system_id)
    |> Enum.uniq()
    |> Map.new(&{&1, visible_system(state, &1)})
  end

  defp refresh_sighting(%Faction.Sighting{status: "live", kind: "fleet"} = sighting, state, _systems) do
    case Enum.find(state.detected_objects, &(&1.character_id == sighting.character_id)) do
      nil -> confirm_lost_fleet(sighting, state)
      blip -> Faction.Sighting.track_fleet(sighting, blip)
    end
  end

  defp refresh_sighting(%Faction.Sighting{status: "live", kind: "agent"} = sighting, _state, systems) do
    case Map.get(systems, sighting.system_id) do
      {:ok, %{characters: characters}} when is_list(characters) ->
        if Enum.any?(characters, &(&1.id == sighting.character_id)),
          do: sighting,
          else: Faction.Sighting.lose(sighting, "hidden")

      # below the contact level that shows who stands in a system
      {:ok, _system} ->
        Faction.Sighting.lose(sighting, "no_contact")

      # the system did not answer: no evidence either way, look again next tick
      _ ->
        sighting
    end
  end

  defp refresh_sighting(sighting, _state, _systems), do: sighting

  # The radar sweep no longer returns the fleet. The sweep can also miss
  # one that is still there (its position lookup timed out), and a lost
  # sighting is final, so ask the fleet itself before giving up on it.
  defp confirm_lost_fleet(sighting, state) do
    # one attempt: a fleet whose process is gone is not worth the retry sleep
    case Game.call_no_log(state.instance_id, :character, sighting.character_id, :get_position, 1) do
      {:ok, {character, %Position{} = position, _angle}} ->
        {target, _target_position} = current_leg(character)

        same_leg? =
          Map.get(character, :action_status) == :moving and
            (is_nil(sighting.system_id) or target == sighting.system_id)

        cond do
          same_leg? and in_radar?(state, position) -> %{sighting | position: position}
          same_leg? -> Faction.Sighting.lose(sighting, "out_of_range")
          true -> Faction.Sighting.lose(sighting, fleet_lost_reason(sighting, state))
        end

      _ ->
        Faction.Sighting.lose(sighting, "out_of_range")
    end
  end

  # "Arrived" is only said when the faction could have watched it happen:
  # the destination lies inside its own S.L.S.D. coverage. Anywhere else
  # the fleet simply left the screen.
  defp fleet_lost_reason(%{target_position: %Position{} = target}, state) do
    if in_radar?(state, target), do: "arrived", else: "out_of_range"
  end

  defp fleet_lost_reason(_sighting, _state), do: "out_of_range"

  defp in_radar?(state, %Position{} = position) do
    Enum.any?(Map.values(state.radars), &Position.in_disk(position, &1.disk))
  end

  defp in_radar?(_state, _position), do: false

  defp detect_changes({change, state}, prev_state) do
    prev_detected_characters_id = Enum.map(prev_state.detected_objects, fn object -> object.character_id end)
    new_object_in_radar? = Enum.any?(state.detected_objects, &(&1.character_id not in prev_detected_characters_id))

    # detect if new object entered into the radar
    change =
      if new_object_in_radar?,
        do: MapSet.put(change, :new_object_in_radar),
        else: change

    # no update when the radar was empty and it still is
    change =
      if Enum.empty?(prev_state.detected_objects) and Enum.empty?(state.detected_objects),
        do: change,
        else: MapSet.put(change, :update_object)

    {change, state}
  end

  # Icon placement / removal
  #
  # `place_icon/4` and `remove_icon/3` perform the in-memory updates
  # plus the synchronous DB write through RC.Instances.SystemIcons.
  # Both return `{:ok, state, info}` on success and `{:error, reason}`
  # on rejection, so the channel can surface the error to the client
  # rather than silently dropping (chat-style) — placement failures are
  # user-visible (cap reached, rate limited, bad kind).
  #
  # `info` for place: `%{previous: prev_or_nil, current: new_icon}`.
  # `info` for remove: removed icon struct or nil.
  #
  # `placed_at` semantics: filled in here (Faction module), not in
  # Faction.SystemIcon, so the same value goes to DB (via attrs) and
  # to the in-memory struct (via from_db on the inserted row).

  def place_icon(state, placer_id, system_id, kind)
      when is_integer(placer_id) and is_integer(system_id) and is_binary(kind) do
    cond do
      kind not in RC.Instances.SystemIcon.kinds() ->
        {:error, :invalid_kind}

      rate_limited?(state, placer_id) ->
        {:error, :rate_limited}

      icon_count_for(state, placer_id) >= @max_icons_per_player and
          not replacing_own_icon?(state, placer_id, system_id) ->
        {:error, :cap_reached}

      true ->
        attrs = %{
          instance_id: state.instance_id,
          faction_id: state.id,
          system_id: system_id,
          placer_profile_id: placer_id,
          icon_kind: kind
        }

        case RC.Instances.SystemIcons.place(attrs) do
          {:ok, %{previous: previous, current: current}} ->
            new_icon = Faction.SystemIcon.from_db(current)
            icons = [new_icon | reject_at(state.icons, system_id)]

            state =
              state
              |> put_icons(icons)
              |> stamp_rate_bucket(placer_id)

            {:ok, state, %{previous: previous, current: new_icon}}

          {:error, _changeset} ->
            {:error, :db_error}
        end
    end
  end

  def place_icon(_state, _placer_id, _system_id, _kind), do: {:error, :invalid_payload}

  def remove_icon(state, requester_id, system_id)
      when is_integer(requester_id) and is_integer(system_id) do
    cond do
      rate_limited?(state, requester_id) ->
        {:error, :rate_limited}

      true ->
        case Enum.find(state.icons, &(&1.system_id == system_id)) do
          nil ->
            {:ok, state, nil}

          existing ->
            {:ok, _row} =
              RC.Instances.SystemIcons.remove(state.instance_id, state.id, system_id)

            state =
              state
              |> put_icons(reject_at(state.icons, system_id))
              |> stamp_rate_bucket(requester_id)

            {:ok, state, existing}
        end
    end
  end

  def remove_icon(_state, _requester_id, _system_id), do: {:error, :invalid_payload}

  defp put_icons(state, icons), do: %{state | icons: icons}

  defp reject_at(icons, system_id),
    do: Enum.reject(icons, &(&1.system_id == system_id))

  defp icon_count_for(state, placer_id),
    do: Enum.count(state.icons, &(&1.placer_id == placer_id))

  defp replacing_own_icon?(state, placer_id, system_id) do
    case Enum.find(state.icons, &(&1.system_id == system_id)) do
      %Faction.SystemIcon{placer_id: ^placer_id} -> true
      _ -> false
    end
  end

  # Sliding-window rate limit. Each placer's recent op timestamps live
  # in a small list (capped at @icon_rate_limit_max entries) and we
  # prune entries older than the window on every check.
  defp rate_limited?(state, placer_id) do
    now = :os.system_time(:millisecond)
    cutoff = now - @icon_rate_limit_window_ms

    bucket =
      state.icon_rate_buckets
      |> Map.get(placer_id, [])
      |> Enum.take_while(&(&1 > cutoff))

    length(bucket) >= @icon_rate_limit_max
  end

  defp stamp_rate_bucket(state, placer_id) do
    now = :os.system_time(:millisecond)
    cutoff = now - @icon_rate_limit_window_ms

    bucket =
      state.icon_rate_buckets
      |> Map.get(placer_id, [])
      |> Enum.take_while(&(&1 > cutoff))

    %{state | icon_rate_buckets: Map.put(state.icon_rate_buckets, placer_id, [now | bucket])}
  end

  defp filter_radar_by_visibility(state) do
    :maps.filter(
      fn system_id, radar ->
        contact = get_system_contact(state, system_id)

        is_same_faction = radar.faction_id == state.id
        has_max_visibility = contact.value == 5

        # TODO
        # ajouter les modificateurs contextuel
        # - en guerre -> -1
        # - allié -> +1

        is_same_faction or has_max_visibility
      end,
      state.all_radars
    )
  end
end
