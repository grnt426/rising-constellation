defmodule Portal.Controllers.FactionChannel do
  use Phoenix.Channel
  use Portal.ReplayRecorder

  alias Portal.Presence
  alias Instance.Galaxy.Galaxy

  # Intercept every server→client broadcast on this faction channel so we
  # can rewrite the `detected_objects` payload per recipient before push.
  # See sanitize_for_viewer/2 below — the only payload shape it actually
  # transforms is the radar blip list (either standalone or embedded in
  # `faction_faction`). Everything else passes through verbatim.
  intercept(["broadcast"])

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
              |> assign(:joined_at, :os.system_time(:seconds))

            case Game.call(instance_id, :faction, faction_id, :get_state) do
              {:ok, faction} ->
                Portal.Socket.gc(socket)
                # Join reply is per-socket — sanitize the nested
                # detected_objects directly with the joining player's id
                # so the same {faction, position, angle} contract applies
                # to the initial state the client receives.
                faction =
                  faction
                  |> sanitize_faction_for_viewer(profile_id)
                  |> filter_stale_deploy_chat(socket)

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

    # Deploy-notice watcher: while a deployment is in flight, re-assert
    # the SYSTEM chat line on every join so players who load the match
    # after the initial fan-out still see it. The agent-side dedup
    # (:push_system_message_once) makes this idempotent.
    if RC.Deploy.get_flag() do
      Game.cast(
        socket.assigns.instance_id,
        :faction,
        socket.assigns.faction_id,
        {:push_system_message_once, RC.Deploy.ongoing_message()}
      )
    end

    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  record("get_system", %{"system_id" => system_id}, socket) do
    query = {:get_system_state, system_id}
    system_with_visibility = Game.call(socket.assigns.instance_id, :faction, socket.assigns.faction_id, query)

    {:ok, %{system: system_with_visibility}}
  end

  record("get_galactic_survey", %{}, socket) do
    case Game.call(socket.assigns.instance_id, :faction, socket.assigns.faction_id, :get_galactic_survey) do
      {:ok, rows} -> {:ok, %{rows: rows}}
      _ -> {:error, %{reason: "survey_unavailable"}}
    end
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

  # Faction-scoped audit log. Read-only from the client side; rows
  # are written by Faction.Agent on cross-player icon overwrites and
  # removals. Returns the latest 100 entries, newest first — the
  # Reports panel renders them as a flat list under an "Icon
  # removals" tab. No pagination yet; if a faction's log grows past
  # 100 in active use we'll add page/limit args.
  record("get_icon_event_log", _payload, socket) do
    entries =
      RC.Instances.FactionEventLogs.list_for_faction(
        socket.assigns.instance_id,
        socket.assigns.faction_id
      )

    {:ok, %{entries: entries}}
  end

  # ------------------------------------------------------------------
  # Faction government (elections)
  #
  # Same boundary rules as icons/chat: payload SHAPE is validated here,
  # game rules live in the agent/engine; actor ids are always the
  # JWT-bound socket player, never client payload; bots are gated out
  # (they neither vote nor stand — quorums count humans).
  #
  # SECRECY: the government struct that rides `faction_faction`
  # broadcasts never contains votes or stakes (see Ballot.jason/0); a
  # viewer's own ballot entries travel only in this per-socket
  # get_government reply.
  # ------------------------------------------------------------------

  @government_seats %{"leader" => :leader, "economy" => :economy, "military" => :military}

  record("get_government", _payload, socket) do
    case government_call(socket, {:get_government, socket.assigns.player_id}) do
      {:ok, reply} -> {:ok, reply}
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  record("gov_nominate", %{"ballot_id" => ballot_id, "candidate_id" => candidate_id}, socket) do
    cond do
      not is_integer(ballot_id) or not is_integer(candidate_id) ->
        {:error, %{reason: :invalid_payload}}

      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      true ->
        government_result(
          government_call(
            socket,
            {:gov_nominate, socket.assigns.player_id, ballot_id, candidate_id}
          )
        )
    end
  end

  # Vote payloads per ballot kind (extra keys ignored):
  #   plurality:    {"candidate_id" => id}
  #   approval:     {"choice" => "approve" | "reject"}
  #   stake_pledge: {"candidate_id" => id, "pct" => 0..100}
  #   stake_bid:    {"candidate_id" => id, "amount" => credits (new total)}
  record("gov_vote", payload, socket) do
    ballot_id = Map.get(payload, "ballot_id")

    cond do
      not is_integer(ballot_id) ->
        {:error, %{reason: :invalid_payload}}

      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      true ->
        case vote_payload(payload) do
          {:ok, vote} ->
            government_result(government_call(socket, {:gov_vote, socket.assigns.player_id, ballot_id, vote}))

          :error ->
            {:error, %{reason: :invalid_payload}}
        end
    end
  end

  record("gov_appoint", %{"seat" => seat, "appointee_id" => appointee_id}, socket) do
    cond do
      not is_integer(appointee_id) ->
        {:error, %{reason: :invalid_payload}}

      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      true ->
        case Map.get(@government_seats, seat) do
          nil ->
            {:error, %{reason: :invalid_seat}}

          seat_atom ->
            government_result(
              government_call(
                socket,
                {:gov_appoint, socket.assigns.player_id, seat_atom, appointee_id}
              )
            )
        end
    end
  end

  record("gov_by_election", %{"seat" => seat}, socket) do
    cond do
      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      true ->
        case Map.get(@government_seats, seat) do
          nil ->
            {:error, %{reason: :invalid_seat}}

          seat_atom ->
            government_result(government_call(socket, {:gov_by_election, socket.assigns.player_id, seat_atom}))
        end
    end
  end

  # Mid-term accountability: deposition votes, Synelle snaps, the ARK
  # challenge. Same conventions: shape checks here, rules in the engine.
  record("gov_depose", %{"seat" => seat}, socket) do
    cond do
      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      true ->
        case Map.get(@government_seats, seat) do
          nil ->
            {:error, %{reason: :invalid_seat}}

          seat_atom ->
            government_result(government_call(socket, {:gov_depose, socket.assigns.player_id, seat_atom}))
        end
    end
  end

  @snap_targets %{"cabinet" => :cabinet, "leader" => :leader, "crisis" => :crisis}

  record("gov_snap", %{"target" => target}, socket) do
    cond do
      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      true ->
        case Map.get(@snap_targets, target) do
          nil ->
            {:error, %{reason: :invalid_payload}}

          target_atom ->
            government_result(government_call(socket, {:gov_snap, socket.assigns.player_id, target_atom}))
        end
    end
  end

  record("gov_challenge", %{"stake" => stake}, socket) do
    cond do
      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      not is_integer(stake) or stake <= 0 ->
        {:error, %{reason: :invalid_payload}}

      true ->
        government_result(government_call(socket, {:gov_challenge, socket.assigns.player_id, stake}))
    end
  end

  record("gov_challenge_match", %{"amount" => amount} = payload, socket) do
    use_treasury = Map.get(payload, "use_treasury", false) == true

    cond do
      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      not is_integer(amount) or amount <= 0 ->
        {:error, %{reason: :invalid_payload}}

      true ->
        government_result(
          government_call(
            socket,
            {:gov_challenge_match, socket.assigns.player_id, amount, use_treasury}
          )
        )
    end
  end

  # DEV ONLY: fast-forward the faction's government clock by `ut`
  # game-time units (see the matching handler in Faction.Agent). Not
  # routed in prod — the :environment gate makes this a 404-equivalent
  # error there even if a client sends it.
  record("gov_debug_advance", %{"ut" => ut}, socket) do
    cond do
      Application.get_env(:rc, :environment) != :dev ->
        {:error, %{reason: :not_available}}

      not is_number(ut) or ut <= 0 or ut > 1_000_000 ->
        {:error, %{reason: :invalid_payload}}

      true ->
        government_result(government_call(socket, {:gov_debug_advance, ut}))
    end
  end

  # Treasury economy: taxes, faction research, laws. Same conventions as
  # the election RPCs — shape checks here, rules in the engine, actor is
  # the JWT-bound player, bots gated out. Atoms are built ONLY through
  # whitelists or to_existing_atom (content keys already exist as atoms
  # from the loaded data modules).
  record("gov_set_taxes", %{"rates" => rates}, socket) do
    cond do
      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      not is_map(rates) ->
        {:error, %{reason: :invalid_payload}}

      not Enum.all?(["credit", "technology", "ideology"], &is_number(Map.get(rates, &1))) ->
        {:error, %{reason: :invalid_payload}}

      true ->
        parsed = %{
          credit: Map.get(rates, "credit"),
          technology: Map.get(rates, "technology"),
          ideology: Map.get(rates, "ideology")
        }

        government_result(government_call(socket, {:gov_set_taxes, socket.assigns.player_id, parsed}))
    end
  end

  record("gov_distribute_treasury", %{"pct" => pct}, socket) do
    cond do
      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      not is_number(pct) ->
        {:error, %{reason: :invalid_payload}}

      true ->
        government_result(government_call(socket, {:gov_distribute_treasury, socket.assigns.player_id, pct}))
    end
  end

  # Treasury flows (user design 2026-07-09): capped member withdrawals,
  # free grants by the Head of Economy, uncapped member donations.
  record("gov_set_withdraw_cap", %{"pct" => pct}, socket) do
    cond do
      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      not is_number(pct) ->
        {:error, %{reason: :invalid_payload}}

      true ->
        government_result(government_call(socket, {:gov_set_withdraw_cap, socket.assigns.player_id, pct}))
    end
  end

  record("gov_withdraw", %{"amounts" => amounts}, socket) do
    case parse_amounts(amounts) do
      nil ->
        {:error, %{reason: :invalid_payload}}

      parsed ->
        if socket.assigns.account.is_bot do
          {:error, %{reason: :forbidden_bot}}
        else
          government_result(government_call(socket, {:gov_withdraw, socket.assigns.player_id, parsed}))
        end
    end
  end

  record("gov_grant", %{"player_id" => player_id, "amounts" => amounts}, socket) do
    case parse_amounts(amounts) do
      nil ->
        {:error, %{reason: :invalid_payload}}

      parsed ->
        cond do
          socket.assigns.account.is_bot ->
            {:error, %{reason: :forbidden_bot}}

          not is_integer(player_id) ->
            {:error, %{reason: :invalid_payload}}

          true ->
            government_result(government_call(socket, {:gov_grant, socket.assigns.player_id, player_id, parsed}))
        end
    end
  end

  record("gov_donate", %{"amounts" => amounts}, socket) do
    case parse_amounts(amounts) do
      nil ->
        {:error, %{reason: :invalid_payload}}

      parsed ->
        if socket.assigns.account.is_bot do
          {:error, %{reason: :forbidden_bot}}
        else
          government_result(government_call(socket, {:gov_donate, socket.assigns.player_id, parsed}))
        end
    end
  end

  record("gov_purchase_patent", %{"key" => key}, socket) do
    government_purchase(socket, :gov_purchase_patent, key)
  end

  record("gov_purchase_lex", %{"key" => key}, socket) do
    government_purchase(socket, :gov_purchase_lex, key)
  end

  record("gov_update_laws", %{"keys" => keys}, socket) do
    cond do
      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      not is_list(keys) or not Enum.all?(keys, &is_binary/1) or length(keys) > 10 ->
        {:error, %{reason: :invalid_payload}}

      true ->
        case parse_existing_atoms(keys) do
          {:ok, parsed} ->
            government_result(government_call(socket, {:gov_update_laws, socket.assigns.player_id, parsed}))

          :error ->
            {:error, %{reason: :unknown_key}}
        end
    end
  end

  # Diplomacy: leader-gated via the faction agent, which relays to the
  # per-instance Diplomacy.Agent. Standings are PAIRWISE-PRIVATE (user
  # rule 2026-07-09): a member sees only the pairs their own faction
  # belongs to, never third-party standings.
  record("get_diplomacy", _payload, socket) do
    case Game.call(socket.assigns.instance_id, :diplomacy, :master, :get_state) do
      {:ok, diplomacy} ->
        {:ok,
         %{
           diplomacy: Instance.Diplomacy.Diplomacy.public_view(diplomacy, socket.assigns.faction_id)
         }}

      _ ->
        {:error, %{reason: :diplomacy_unavailable}}
    end
  end

  # The diplomacy panel's action feed: this faction's audit entries for
  # stance changes and hostile actions, newest first.
  record("get_diplomacy_log", _payload, socket) do
    entries =
      RC.Instances.FactionEventLogs.list_for_faction_by_types(
        socket.assigns.instance_id,
        socket.assigns.faction_id,
        ["diplomacy_changed", "diplomacy_action"]
      )

    {:ok, %{entries: entries}}
  end

  record("gov_diplomacy_declare_war", %{"faction_id" => fid}, socket) do
    government_diplomacy(socket, fn -> {:declare_war, fid} end, is_integer(fid))
  end

  record("gov_diplomacy_propose", %{"faction_id" => fid, "kind" => kind}, socket) do
    parsed =
      case kind do
        "non_aggression" -> :non_aggression
        "peace" -> :peace
        _ -> nil
      end

    government_diplomacy(
      socket,
      fn -> {:propose, fid, parsed} end,
      is_integer(fid) and parsed != nil
    )
  end

  record("gov_diplomacy_accept", %{"proposal_id" => pid}, socket) do
    government_diplomacy(socket, fn -> {:accept, pid} end, is_integer(pid))
  end

  record("gov_diplomacy_reject", %{"proposal_id" => pid}, socket) do
    government_diplomacy(socket, fn -> {:reject, pid} end, is_integer(pid))
  end

  record("gov_diplomacy_break", %{"faction_id" => fid}, socket) do
    government_diplomacy(socket, fn -> {:break_pact, fid} end, is_integer(fid))
  end

  defp government_diplomacy(socket, action, valid?) do
    cond do
      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      not valid? ->
        {:error, %{reason: :invalid_payload}}

      true ->
        government_result(government_call(socket, {:gov_diplomacy, socket.assigns.player_id, action.()}))
    end
  end

  defp government_purchase(socket, op, key) do
    cond do
      socket.assigns.account.is_bot ->
        {:error, %{reason: :forbidden_bot}}

      not is_binary(key) ->
        {:error, %{reason: :invalid_payload}}

      true ->
        case parse_existing_atoms([key]) do
          {:ok, [parsed]} ->
            government_result(government_call(socket, {op, socket.assigns.player_id, parsed}))

          :error ->
            {:error, %{reason: :unknown_key}}
        end
    end
  end

  # Resource-amount payloads for the treasury flows: non-negative
  # numbers under the three known keys; anything else is rejected.
  defp parse_amounts(amounts) when is_map(amounts) do
    parsed = %{
      credit: Map.get(amounts, "credit", 0),
      technology: Map.get(amounts, "technology", 0),
      ideology: Map.get(amounts, "ideology", 0)
    }

    valid? =
      Enum.all?(Map.values(parsed), fn amount ->
        is_number(amount) and amount >= 0 and amount <= 1_000_000_000
      end) and Enum.any?(Map.values(parsed), &(&1 > 0))

    if valid?, do: parsed, else: nil
  end

  defp parse_amounts(_amounts), do: nil

  defp parse_existing_atoms(strings) do
    {:ok, Enum.map(strings, &String.to_existing_atom/1)}
  rescue
    ArgumentError -> :error
  end

  defp government_call(socket, message) do
    Game.call(socket.assigns.instance_id, :faction, socket.assigns.faction_id, message)
  end

  defp government_result(:ok), do: :ok
  defp government_result({:error, reason}), do: {:error, %{reason: reason}}
  defp government_result(_other), do: {:error, %{reason: :government_unavailable}}

  # Only well-typed vote payloads cross the boundary — the atoms the
  # engine matches on are built HERE from whitelisted strings, never
  # via String.to_atom on client input.
  defp vote_payload(payload) do
    candidate_id = Map.get(payload, "candidate_id")

    cond do
      Map.has_key?(payload, "choice") ->
        case Map.get(payload, "choice") do
          "approve" -> {:ok, %{choice: :approve}}
          "reject" -> {:ok, %{choice: :reject}}
          _ -> :error
        end

      Map.has_key?(payload, "pct") ->
        pct = Map.get(payload, "pct")

        if is_integer(candidate_id) and is_number(pct) and pct >= 0 and pct <= 100,
          do: {:ok, %{candidate_id: candidate_id, pct: pct}},
          else: :error

      Map.has_key?(payload, "amount") ->
        amount = Map.get(payload, "amount")

        if is_integer(candidate_id) and is_integer(amount),
          do: {:ok, %{candidate_id: candidate_id, amount: amount}},
          else: :error

      is_integer(candidate_id) ->
        {:ok, %{candidate_id: candidate_id}}

      true ->
        :error
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

  # Per-recipient sanitization of the `broadcast` event. Faction.Agent
  # broadcasts the radar blip list with its full internal shape — each
  # blip carries `character_id` (used by Faction.detect_changes/2) and
  # `owner_player_id` (used here). For each connected socket we drop the
  # blips owned by *that viewer's* characters and strip the two internal
  # keys before push.
  #
  # The previous Stage 8 fix dropped the viewer's whole faction
  # server-side, which over-corrected: faction-mates' Navarchs that
  # entered radar range used to render as anonymous, faction-colored
  # blips and that behavior is intentional (see the Legend's "Detected"
  # row). Filtering per-player here restores that without re-leaking
  # character_id — the player_id check happens before serialization.
  #
  # Forward-compatible with diplomatic states: today any blip whose
  # `owner_player_id` is the viewer is filtered; if we later want
  # "Coordinated Movements" to also share *enemy* faction positions
  # with an ally, that's a server-side decision in
  # Faction.update_detected_object/1 about which characters end up in
  # `detected_objects`, not a change here. The channel boundary stays
  # narrow: "your own characters never appear as anonymous blips".
  def handle_out("broadcast", payload, socket) do
    payload =
      payload
      |> sanitize_for_viewer(socket.assigns.player_id)
      |> filter_deploy_chat_payload(socket)

    push(socket, "broadcast", payload)
    {:noreply, socket}
  end

  # Deploy-notice chat hygiene, applied per recipient at serve time (join
  # reply + every faction_faction push). The ring itself is never touched
  # and nothing extra is broadcast, so a client that was connected during
  # the deploy keeps its copy until it refreshes — while a client that
  # loads the game later never receives the stale lines:
  #   * the "deployment on-going" line is only real while the deploy flag
  #     is up (late joiners during the window still get it via the
  #     after_join re-assert);
  #   * the "update applied, refresh" line only makes sense for sockets
  #     that were already connected when it fired — a freshly loaded
  #     client is already running the new code.
  defp filter_deploy_chat_payload(%{faction_faction: faction} = payload, socket) do
    %{payload | faction_faction: filter_stale_deploy_chat(faction, socket)}
  end

  defp filter_deploy_chat_payload(payload, _socket), do: payload

  defp filter_stale_deploy_chat(%{chat: chat} = faction, socket) when is_list(chat) do
    # Missing assign (shouldn't happen) fails open to the old behavior.
    joined_at = Map.get(socket.assigns, :joined_at, 0)

    %{faction | chat: RC.Deploy.filter_stale_chat(chat, joined_at, RC.Deploy.get_flag())}
  end

  defp filter_stale_deploy_chat(faction, _socket), do: faction

  defp sanitize_for_viewer(%{detected_objects: blips} = payload, viewer_player_id) do
    %{payload | detected_objects: sanitize_blips(blips, viewer_player_id)}
  end

  defp sanitize_for_viewer(%{faction_faction: faction} = payload, viewer_player_id) do
    %{payload | faction_faction: sanitize_faction_for_viewer(faction, viewer_player_id)}
  end

  defp sanitize_for_viewer(payload, _viewer_player_id), do: payload

  defp sanitize_faction_for_viewer(%{detected_objects: blips} = faction, viewer_player_id) do
    %{faction | detected_objects: sanitize_blips(blips, viewer_player_id)}
  end

  defp sanitize_faction_for_viewer(faction, _viewer_player_id), do: faction

  defp sanitize_blips(blips, viewer_player_id) do
    Enum.flat_map(blips, fn blip ->
      if Map.get(blip, :owner_player_id) == viewer_player_id do
        []
      else
        [%{faction: blip.faction, position: blip.position, angle: blip.angle}]
      end
    end)
  end
end
