defmodule Instance.Faction.Agent do
  use Core.TickServer

  alias Instance.Faction.Faction
  alias Instance.Faction.Character
  alias Instance.Faction.GalacticSurvey
  alias Instance.Faction.Market
  alias Instance.Faction.StellarSystem
  alias Portal.Controllers.FactionChannel

  require Logger

  @decorate tick()
  def on_call(:get_state, _from, state) do
    {:reply, {:ok, state.data}, state}
  end

  @decorate tick()
  def on_call(:get_galactic_survey, _, state) do
    {cache, rows} =
      GalacticSurvey.get_or_build(state.data.galactic_survey_cache, state.data, state.instance_id)

    data = %{state.data | galactic_survey_cache: cache}
    {:reply, {:ok, rows}, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:get_system_state, system_id}, _, state) do
    case Game.call(state.instance_id, :stellar_system, system_id, :get_state) do
      {:ok, system} ->
        contact = Faction.resolve_system_visibility(state.data, system)

        # Note: this path obfuscates with Instance.StellarSystem.Character — a
        # summary struct without :army / :action_status — so the F4/F8 leak
        # surfaces from the Stage 8 fix are not present here, and there is no
        # viewer_faction_key to plumb. F4/F8 protections apply on the
        # :get_character_state path below, which goes through Faction.Character.
        obfuscated_system =
          StellarSystem.obfuscate(system, contact, state.data.id, state.instance_id)

        {:reply, obfuscated_system, state}

      error ->
        Logger.error(error)
        {:reply, :error, state}
    end
  end

  @decorate tick()
  def on_call({:get_character_state, character_id}, _, state) do
    with {:ok, character} <- Game.call(state.instance_id, :character, character_id, :get_state),
         {:ok, system} <- Game.call(state.instance_id, :stellar_system, character.system, :get_state) do
      visibility = Faction.resolve_character_visibility(state.data, system, character)

      # Stage 8 F4/F8: same as :get_system_state — forward our own
      # faction key so the obfuscation can distinguish own-faction
      # characters from cross-faction characters viewed at the same
      # visibility tier.
      obfuscated_character = Character.obfuscate(character, visibility, state.data.key)

      {:reply, obfuscated_character, state}
    else
      _error -> {:reply, :error, state}
    end
  end

  @decorate tick()
  def on_call({:get_system_informer_count, system_id}, _, state) do
    contacts = Faction.get_system_contact(state.data, system_id)
    informer = Map.get(contacts.details, :informer, [])
    {:reply, {:ok, length(informer)}, state}
  end

  @decorate tick()
  def on_call({:add_player, player}, _, state) do
    data = Faction.add_player(state.data, player)
    faction_data = Data.Querier.one(Data.Game.Faction, state.instance_id, state.data.key)

    FactionChannel.broadcast_change(state.channel, %{faction_faction: data})
    Game.cast(state.instance_id, :victory, :master, {:add_player, state.data.id})

    if state.speed != :fast do
      RC.PlayerEvents.create(%{
        type: "faction",
        key: "new_player",
        data: Jason.encode!(%{player: player.name, theme: faction_data.theme}),
        instance_id: state.instance_id,
        faction_id: state.data.id
      })
    end

    {:reply, :ok, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:drop_explorer, system_id, player_name}, _, state) do
    {response, contact, data} = Faction.drop_system_explorer(state.data, system_id, player_name)
    system_and_contact = %{system_id: system_id, contact: contact}

    FactionChannel.broadcast_change(state.channel, %{faction_faction_contact: system_and_contact})
    Game.cast(state.instance_id, :galaxy, :master, {:update_contacts, data.key, data.contacts})

    {:reply, response, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:drop_informer, system_id, player_name, count}, _, state) do
    {change, contact, data} = Faction.drop_system_informer(state.data, system_id, player_name, count)

    if MapSet.member?(change, :dropped) do
      system_and_contact = %{system_id: system_id, contact: contact}
      Game.cast(state.instance_id, :galaxy, :master, {:update_contacts, data.key, data.contacts})
      FactionChannel.broadcast_change(state.channel, %{faction_faction_contact: system_and_contact})
    end

    if MapSet.member?(change, :radar_update) do
      FactionChannel.broadcast_change(state.channel, %{faction_faction: data})
    end

    {:reply, :ok, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:send_resources, from_player_id, to_player_id, resources}, _, state) do
    {action, result, state} = Market.send_resources(state, {from_player_id, to_player_id, resources})

    if result == :ok do
      name = Faction.get_player_name(state.data, from_player_id)
      notif = Notification.Text.new(:receive_resources, nil, %{player: name, resources: resources})
      Game.cast(state.instance_id, :player, to_player_id, {:push_notifs, notif})
    end

    FactionChannel.broadcast_change(state.channel, %{faction_faction: state.data})
    {action, result, state}
  end

  # Player-icon placement. Returns `:ok` or `{:error, reason}` to the
  # channel so cap / rate-limit / bad-kind rejections are user-visible
  # (chat-style silent drops would let a buggy client think its
  # placement succeeded). On success, broadcast the whole faction
  # struct — same pattern as chat — so every member's in-memory copy
  # of `:icons` stays in sync without a bespoke delta message.
  #
  # Authority: `placer_id` is passed from the channel as
  # `socket.assigns.player_id`, never trusted from the client payload.
  @decorate tick()
  def on_call({:place_icon, placer_id, system_id, kind}, _from, state) do
    case Faction.place_icon(state.data, placer_id, system_id, kind) do
      {:ok, data, info} ->
        FactionChannel.broadcast_change(state.channel, %{faction_faction: data})
        # The audit-log write is fire-and-forget — a DB hiccup here
        # shouldn't roll back a successful placement that already
        # broadcast to the faction. Cross-player overwrites only;
        # self-overwrites are excluded by the guard inside
        # log_icon_replaced/4.
        log_icon_replaced(%{state | data: data}, placer_id, info, kind)
        {:reply, :ok, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:remove_icon, requester_id, system_id}, _from, state) do
    case Faction.remove_icon(state.data, requester_id, system_id) do
      {:ok, data, removed} ->
        FactionChannel.broadcast_change(state.channel, %{faction_faction: data})
        log_icon_removed(%{state | data: data}, requester_id, removed)
        {:reply, :ok, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Cross-player icon replacement: log who overwrote whose marker
  # with what. Self-overwrites (player changes their mind about
  # their own icon) are silently skipped — the user-visible
  # accountability surface would otherwise fill with noise.
  defp log_icon_replaced(_state, _placer_id, %{previous: nil}, _new_kind), do: :ok

  defp log_icon_replaced(_state, placer_id, %{previous: %{placer_profile_id: same}}, _new_kind)
       when same == placer_id,
       do: :ok

  defp log_icon_replaced(state, placer_id, %{previous: previous, current: current}, new_kind) do
    write_log_entry(state, "icon_replaced", placer_id, previous.placer_profile_id, %{
      system_id: current.system_id,
      system_name: fetch_system_name(state.instance_id, current.system_id),
      previous_kind: previous.icon_kind,
      new_kind: new_kind,
      actor_name: Faction.get_player_name(state.data, placer_id),
      target_name: Faction.get_player_name(state.data, previous.placer_profile_id)
    })
  end

  defp log_icon_removed(_state, _requester_id, nil), do: :ok

  defp log_icon_removed(_state, requester_id, %{placer_id: same}) when same == requester_id,
    do: :ok

  defp log_icon_removed(state, requester_id, removed) do
    write_log_entry(state, "icon_removed", requester_id, removed.placer_id, %{
      system_id: removed.system_id,
      system_name: fetch_system_name(state.instance_id, removed.system_id),
      icon_kind: removed.kind,
      actor_name: Faction.get_player_name(state.data, requester_id),
      target_name: Faction.get_player_name(state.data, removed.placer_id)
    })
  end

  defp write_log_entry(state, event_type, actor_id, target_id, payload) do
    case RC.Instances.FactionEventLogs.record(%{
           instance_id: state.instance_id,
           faction_id: state.data.id,
           actor_profile_id: actor_id,
           target_profile_id: target_id,
           event_type: event_type,
           payload: payload
         }) do
      {:ok, _entry} ->
        :ok

      {:error, changeset} ->
        # Audit logging is best-effort. Surface the failure to the
        # operator log but don't crash the per-faction agent — a
        # missed audit row is recoverable; a downed faction isn't.
        Logger.warning(
          "faction_event_log insert failed: #{inspect(changeset.errors)} " <>
            "(instance=#{state.instance_id}, faction=#{state.data.id}, type=#{event_type})"
        )

        :ok
    end
  end

  defp fetch_system_name(instance_id, system_id) do
    case Game.call(instance_id, :stellar_system, system_id, :get_state) do
      {:ok, %{name: name}} -> name
      _ -> nil
    end
  end

  @decorate tick()
  def on_cast({:remove_informer, system_id}, state) do
    {change, data} = Faction.remove_informer(state.data, system_id)

    Game.cast(state.instance_id, :galaxy, :master, {:update_contacts, data.key, data.contacts})

    if MapSet.member?(change, :radar_update) do
      FactionChannel.broadcast_change(state.channel, %{faction_faction: data})
    end

    {:noreply, %{state | data: data}}
  end

  # Stage 4 #C1 + #H8 fix.
  #
  # `from` is now the JWT-bound `player_id` (integer) sent from the
  # channel handler — NOT a client-supplied string. We resolve the
  # display name here against the authoritative faction roster, so the
  # stored ChatMessage author always matches the real authenticated
  # sender.
  #
  # Defensive guards on shape: `is_integer(from)` + `is_binary(message)`.
  # The channel boundary already validates this, but the agent is shared
  # by every faction member and any future caller bug would otherwise
  # crash the whole faction. Catch-all returns unchanged state.
  @decorate tick()
  def on_cast({:push_message, from, message}, state)
      when is_integer(from) and is_binary(message) do
    display_name = Faction.get_player_name(state.data, from)
    data = Faction.push_message(state.data, display_name, from, message)
    FactionChannel.broadcast_change(state.channel, %{faction_faction: data})

    {:noreply, %{state | data: data}}
  end

  def on_cast({:push_message, _from, _message}, state) do
    Logger.warning("ignoring malformed :push_message payload")
    {:noreply, state}
  end

  def on_cast({:radar_update, system}, state) do
    data =
      case Faction.radar_update(state.data, system) do
        {:radar_update, data} ->
          FactionChannel.broadcast_change(state.channel, %{faction_faction: data})
          data

        {:no_radar_update, data} ->
          data
      end

    {:noreply, %{state | data: data}}
  end

  @decorate tick()
  def on_info(:tick, state) do
    {:noreply, state}
  end

  # TICK FUNCTIONS

  defp do_next_tick(state, next_tick) do
    {change, data} = Faction.next_tick(state.data, next_tick)

    if MapSet.member?(change, :update_object) do
      # Broadcast the internal blip list verbatim. Per-recipient
      # sanitization (drop the viewer's own characters, strip
      # `character_id` + `owner_player_id`) runs in
      # Portal.Controllers.FactionChannel.handle_out/3 — see the
      # sanitize_for_viewer/2 path there. Doing it at the channel
      # boundary instead of the agent lets us filter per-player
      # (so faction-mates remain visible as anonymous radar blips),
      # which the previous agent-side faction-wide filter could not
      # express.
      FactionChannel.broadcast_change(state.channel, %{detected_objects: data.detected_objects})
    end

    if MapSet.member?(change, :new_object_in_radar) do
      notif = Notification.Sound.new(:new_object_in_radar)
      FactionChannel.broadcast_change(state.channel, %{player_notifs: [notif]})
    end

    {%{state | data: data}, Faction}
  end
end
