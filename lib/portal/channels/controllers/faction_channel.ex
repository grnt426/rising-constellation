defmodule Portal.Controllers.FactionChannel do
  use Phoenix.Channel
  use Portal.ReplayRecorder

  alias Portal.Presence
  alias Instance.Galaxy.Galaxy

  def topic(%{instance_id: instance_id, faction_id: faction_id}) do
    "instance:faction:#{instance_id}:#{faction_id}"
  end

  def join("instance:faction:" <> channel_data, %{"registration" => registration_token}, socket) do
    [instance_id, faction_id] =
      channel_data
      |> String.split(":")
      |> Enum.map(&String.to_integer/1)

    if Instance.Manager.created?(instance_id) do
      # Stage 7 F7. Defensive case-match around Game.call: a crashed
      # Galaxy/Time/Faction agent (which under F6 returns
      # {:error, :callee_crashed}) used to take this channel process
      # down with it. Now it returns a clean instance_unavailable.
      with {:ok, galaxy} <- Game.call(instance_id, :galaxy, :master, :get_state),
           {:ok, time} <- Game.call(instance_id, :time, :master, :get_state) do
        has_replay =
          not (time.speed == :fast or Galaxy.is_tutorial(galaxy) or Application.get_env(:rc, :environment) == :test)

        {profile_id, registration} =
          if Galaxy.is_tutorial(galaxy) do
            # Tutorial: bind to the caller's owned profile. The synthetic
            # registration carries faction_id=1 (the player's faction in
            # `tutorial_data`) so the standard faction_id == faction_id
            # check below works without a tutorial short-circuit.
            if RC.Accounts.own_profile?(socket.assigns.account.id, galaxy.tutorial_id) do
              {galaxy.tutorial_id, %{faction_id: 1}}
            else
              {false, nil}
            end
          else
            case RC.Registrations.valid?(instance_id, registration_token, socket.assigns.account.id) do
              {:ok, registration} -> {registration.profile_id, registration}
              {:error, _} -> {false, nil}
            end
          end

        if profile_id do
          # Removed the previous `Galaxy.is_tutorial(galaxy) or ...` short-
          # circuit — the tutorial branch above supplies a registration with
          # the expected faction_id, so this is now an honest equality test.
          if registration.faction_id == faction_id do
            send(self(), :after_join)

            # assign ids to socket
            socket =
              socket
              |> assign(:instance_id, instance_id)
              |> assign(:faction_id, faction_id)
              |> assign(:player_id, profile_id)
              |> assign(:channel_name, "faction")
              |> assign(:is_tutorial, Galaxy.is_tutorial(galaxy))
              |> assign(:has_replay, has_replay)

            case Game.call(instance_id, :faction, faction_id, :get_state) do
              {:ok, faction} ->
                Portal.Socket.gc(socket)
                {:ok, %{faction_faction: faction}, socket}

              _ ->
                {:error, %{reason: "instance_unavailable"}}
            end
          else
            {:error, %{reason: "invalid_registration (faction id doesn't match)"}}
          end
        else
          {:error, %{reason: "invalid_registration"}}
        end
      else
        _ -> {:error, %{reason: "instance_unavailable"}}
      end
    else
      {:error, %{reason: "instance_not_found"}}
    end
  end

  def handle_info(:after_join, socket) do
    {:ok, _} = Presence.track(socket, socket.assigns.player_id, %{})
    push(socket, "presence_state", Presence.list(socket))

    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  record("get_system", %{"system_id" => system_id}, socket) do
    query = {:get_system_state, system_id}
    system_with_visibility = Game.call(socket.assigns.instance_id, :faction, socket.assigns.faction_id, query)

    {:ok, %{system: system_with_visibility}}
  end

  record("get_character", %{"character_id" => character_id}, socket) do
    query = {:get_character_state, character_id}
    character_with_visibility = Game.call(socket.assigns.instance_id, :faction, socket.assigns.faction_id, query)

    {:ok, %{character: character_with_visibility}}
  end

  # Stage 4 #C1 + #H8 fix.
  #
  # Before: `from` was taken from the client payload and `message` was not
  # type-checked. The agent's downstream `String.length(message)` raised on
  # non-binary input, crashing the per-faction GenServer (DoS for every
  # member). `from` was rendered as authoritative author, enabling
  # impersonation of any player, "GameMaster", admin announcements, etc.
  #
  # After: `from` is derived server-side from `socket.assigns.player_id`
  # (which Stage 3 #1 already binds to the JWT-authenticated account). The
  # `message` is validated as a binary; non-string payloads are rejected
  # with a clean error instead of crashing the Faction.Agent.
  #
  # Chat enrichment (in-game links): messages may embed rich-ref tokens
  # like `[[sys:123|Sol]]`. We cap them server-side as a trust-no-client
  # backstop — the ChatComposer enforces the same limit on the way in.
  # Counting `[[` occurrences is cheap and a legitimate message will
  # never collide.
  @max_chat_refs 10

  record("push_chat_message", %{"message" => message}, socket) do
    cond do
      not is_binary(message) ->
        {:error, %{reason: :invalid_payload}}

      ref_count(message) > @max_chat_refs ->
        {:error, %{reason: :too_many_refs}}

      true ->
        Game.cast(
          socket.assigns.instance_id,
          :faction,
          socket.assigns.faction_id,
          {:push_message, socket.assigns.player_id, message}
        )

        :ok
    end
  end

  defp ref_count(message) do
    message
    |> :binary.matches("[[")
    |> length()
  end

  # Player-placed icons. `placer_id` is sourced server-side from the
  # JWT-bound `socket.assigns.player_id` — never from the client
  # payload — mirroring the same impersonation fix `push_chat_message`
  # got in Stage 4 #C1.
  #
  # Bot gating: stress-test bot accounts cannot place or remove icons.
  # Cheap one-line guard at the channel boundary so the per-faction
  # agent never even sees a bot op (also makes the dashboard reasoning
  # easier: "if it's in the table, a human did it").
  #
  # We delegate validation (icon kind, cap, rate limit) to the agent so
  # the rules live next to the state they constrain — the channel only
  # checks payload shape and gates bots. Errors come back as
  # `{:error, reason}` from `Game.call` and surface to the client as
  # `%{reason: reason}` (same convention as `send_resources`).
  record("place_icon", %{"system_id" => system_id, "icon_kind" => icon_kind}, socket) do
    cond do
      not is_integer(system_id) ->
        {:error, %{reason: :invalid_system_id}}

      not is_binary(icon_kind) ->
        {:error, %{reason: :invalid_icon_kind}}

      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      # Tutorial instances live entirely in memory; their `instance_id`
      # is a timestamp-shaped synthetic value that has no row in the
      # `instances` table, so the FK on `system_icons.instance_id`
      # rejects every insert with a changeset error. Rather than
      # surface a confusing "db_error" toast we explicitly gate the
      # feature out — icons are a faction-communication tool, and
      # tutorials are solo.
      socket.assigns.is_tutorial ->
        {:error, %{reason: :forbidden_tutorial}}

      true ->
        case Game.call(
               socket.assigns.instance_id,
               :faction,
               socket.assigns.faction_id,
               {:place_icon, socket.assigns.player_id, system_id, icon_kind}
             ) do
          :ok -> :ok
          {:error, reason} -> {:error, %{reason: reason}}
        end
    end
  end

  record("remove_icon", %{"system_id" => system_id}, socket) do
    cond do
      not is_integer(system_id) ->
        {:error, %{reason: :invalid_system_id}}

      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      socket.assigns.is_tutorial ->
        {:error, %{reason: :forbidden_tutorial}}

      true ->
        case Game.call(
               socket.assigns.instance_id,
               :faction,
               socket.assigns.faction_id,
               {:remove_icon, socket.assigns.player_id, system_id}
             ) do
          :ok -> :ok
          {:error, reason} -> {:error, %{reason: reason}}
        end
    end
  end

  # Stage 4 #C1 fix (send_resources). Validate the `resources` map at the
  # channel boundary: only well-formed, non-negative numeric entries for
  # the three resource keys are forwarded to the agent. Anything else
  # would have caused a Faction.Agent crash inside Market.send_resources.
  record(
    "send_resources",
    %{"player_id" => to_player_id, "resources" => resources},
    socket
  ) do
    cond do
      not is_integer(to_player_id) ->
        {:error, %{reason: :invalid_player_id}}

      not is_map(resources) ->
        {:error, %{reason: :invalid_resources}}

      not valid_resources_map?(resources) ->
        {:error, %{reason: :invalid_resources}}

      true ->
        case Game.call(
               socket.assigns.instance_id,
               :faction,
               socket.assigns.faction_id,
               {:send_resources, socket.assigns.player_id, to_player_id, resources}
             ) do
          {:error, reason} -> {:error, %{reason: reason}}
          _ -> :ok
        end
    end
  end

  # Only "credit" / "technology" / "ideology" allowed; values must be
  # non-negative integers. Extra keys silently ignored (Market.send_resources
  # only reads these three names) but invalid TYPES would crash the agent
  # — so reject the whole call.
  defp valid_resources_map?(resources) do
    Enum.all?(["credit", "technology", "ideology"], fn k ->
      case Map.get(resources, k, 0) do
        n when is_integer(n) and n >= 0 -> true
        _ -> false
      end
    end)
  end

  def broadcast_change(channel, payload) do
    Portal.Endpoint.broadcast(channel, "broadcast", payload)
  end
end
