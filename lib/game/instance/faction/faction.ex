defmodule Instance.Faction.Faction do
  use TypedStruct
  use Util.MakeEnumerable

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
  @max_chat_messages 80
  @max_length_message 500

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
    do: [except: [:instance_id, :all_radars, :icon_rate_buckets, :galactic_survey_cache]]

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
  def push_message(state, from, from_id, message)
      when is_binary(from) and is_integer(from_id) and is_binary(message) do
    message =
      if String.length(message) > @max_length_message,
        do: String.slice(message, 0..@max_length_message) <> " [...]",
        else: message

    chat = List.flatten(state.chat, [Faction.ChatMessage.new(from, from_id, message)])

    chat =
      if length(chat) > @max_chat_messages do
        [_ | tail] = chat
        tail
      else
        chat
      end

    %{state | chat: chat}
  end

  def push_message(state, _from, _from_id, _message), do: state

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
      # for "new object entered radar" detection) and owner_player_id (used
      # by Portal.Controllers.FactionChannel.handle_out/3 to filter out the
      # viewer's own characters per-recipient). Both fields are stripped at
      # the channel boundary so they never reach the wire — see the
      # sanitize_for_viewer/2 path in faction_channel.ex.
      |> Stream.map(fn {_radar, character, position, angle} ->
        %{
          faction: character.owner.faction,
          character_id: character.id,
          owner_player_id: character.owner.id,
          position: position,
          angle: angle
        }
      end)
      |> Enum.to_list()

    {change, %{state | detected_objects: characters_in_radar}}
  end

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
