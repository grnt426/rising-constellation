defmodule Portal.GovDebugController do
  @moduledoc """
  Harness-secret-gated, DEV-ONLY faction government clock control.

  Advances a faction's government by `ut` game-time units through the
  real engine (`Faction.Agent {:gov_debug_advance, ut}`): founding ends,
  ballots close, quorums and tallies process exactly as if the time had
  passed. Unlike the faction-channel `gov_debug_advance` this is not
  bound to faction membership, so it can drive factions with ZERO
  registered players — the empty-faction edge cases (e.g. an unclaimed
  ARK whose founding ends with nobody to bid).

  Hard-gated to `:environment == :dev` on every action: the harness
  scope itself exists in prod for the bot pipeline, and a prod time-warp
  must not — so even a valid harness secret gets a 404 there.
  """
  use Portal, :controller

  # GET /api/harness/gov-debug/status?iid=6&fid=12
  def status(conn, %{"iid" => iid, "fid" => fid}) do
    with :ok <- dev_only(),
         {:ok, iid, fid} <- parse_ids(iid, fid),
         {:ok, %{government: government}} <-
           Game.call(iid, :faction, fid, {:get_government, nil}) do
      json(conn, %{
        instance_id: iid,
        faction_id: fid,
        phase: government.phase,
        founding_remaining: government.founding.value,
        ballots:
          Enum.map(government.ballots, fn ballot ->
            %{id: ballot.id, seat: ballot.seat, kind: ballot.kind, remaining: ballot.cooldown.value}
          end),
        seats: government.seats,
        treasury: government.treasury,
        withdraw_cap_pct: Map.get(government, :withdraw_cap_pct, 0),
        station_powered: Map.get(government, :station_powered, true),
        station_buildings: Map.get(government, :station_buildings, []),
        gateway_links: Map.get(government, :gateway_links, [])
      })
    else
      {:error, :not_dev} -> conn |> put_status(404) |> json(%{error: :not_available})
      {:error, :invalid_params} -> conn |> put_status(400) |> json(%{error: :invalid_params})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
      other -> conn |> put_status(422) |> json(%{error: inspect(other)})
    end
  end

  # POST /api/harness/gov-debug/advance {"iid": 6, "fid": 12, "ut": 1430.5}
  def advance(conn, %{"iid" => iid, "fid" => fid, "ut" => ut}) do
    with :ok <- dev_only(),
         {:ok, iid, fid} <- parse_ids(iid, fid),
         true <- is_number(ut) and ut > 0 and ut <= 1_000_000,
         :ok <- Game.call(iid, :faction, fid, {:gov_debug_advance, ut}) do
      json(conn, %{advanced: true, instance_id: iid, faction_id: fid, ut: ut})
    else
      {:error, :not_dev} -> conn |> put_status(404) |> json(%{error: :not_available})
      {:error, :invalid_params} -> conn |> put_status(400) |> json(%{error: :invalid_params})
      false -> conn |> put_status(400) |> json(%{error: :invalid_params})
      {:error, reason} -> conn |> put_status(422) |> json(%{advanced: false, error: inspect(reason)})
      other -> conn |> put_status(422) |> json(%{advanced: false, error: inspect(other)})
    end
  end

  # POST /api/harness/gov-debug/deposit {"iid": 6, "fid": 11, "credit": 0, "technology": 5000, "ideology": 5000}
  def deposit(conn, %{"iid" => iid, "fid" => fid} = params) do
    amounts = %{
      credit: Map.get(params, "credit", 0),
      technology: Map.get(params, "technology", 0),
      ideology: Map.get(params, "ideology", 0)
    }

    with :ok <- dev_only(),
         {:ok, iid, fid} <- parse_ids(iid, fid),
         true <- Enum.all?(Map.values(amounts), &(is_number(&1) and &1 >= 0 and &1 <= 10_000_000)),
         :ok <- Game.call(iid, :faction, fid, {:gov_debug_deposit, amounts}) do
      json(conn, %{deposited: true, amounts: amounts})
    else
      {:error, :not_dev} -> conn |> put_status(404) |> json(%{error: :not_available})
      {:error, :invalid_params} -> conn |> put_status(400) |> json(%{error: :invalid_params})
      false -> conn |> put_status(400) |> json(%{error: :invalid_params})
      other -> conn |> put_status(422) |> json(%{error: inspect(other)})
    end
  end

  # GET /api/harness/gov-debug/station-status?iid=7&pid=12
  # A player's directly-held systems with their station state — the
  # station-flow harness needs a system id to aim orders at and the
  # station contents to assert on.
  def station_status(conn, %{"iid" => iid, "pid" => pid}) do
    with :ok <- dev_only(),
         {:ok, iid, pid} <- parse_ids(iid, pid),
         {:ok, player} <- Game.call(iid, :player, pid, :get_state) do
      systems =
        Enum.map(player.stellar_systems, fn s ->
          case Game.call(iid, :stellar_system, s.id, :get_state) do
            {:ok, system} ->
              %{
                id: system.id,
                name: system.name,
                production: system.production.value,
                station: Map.get(system, :station)
              }

            _ ->
              %{id: s.id}
          end
        end)

      json(conn, %{player_id: pid, systems: systems})
    else
      {:error, :not_dev} -> conn |> put_status(404) |> json(%{error: :not_available})
      {:error, :invalid_params} -> conn |> put_status(400) |> json(%{error: :invalid_params})
      other -> conn |> put_status(422) |> json(%{error: inspect(other)})
    end
  end

  # POST /api/harness/gov-debug/station-complete {"iid": 7, "system_id": 123}
  # DEV ONLY: finish the system's running station construction instantly
  # (the gateway e2e can't wait out 256k labor at real production rates).
  def station_complete(conn, %{"iid" => iid, "system_id" => system_id}) do
    with :ok <- dev_only(),
         {:ok, iid, system_id} <- parse_ids(iid, system_id),
         :ok <- Game.call(iid, :stellar_system, system_id, {:station_debug_complete}) do
      json(conn, %{completed: true})
    else
      {:error, :not_dev} -> conn |> put_status(404) |> json(%{error: :not_available})
      {:error, :invalid_params} -> conn |> put_status(400) |> json(%{error: :invalid_params})
      other -> conn |> put_status(422) |> json(%{error: inspect(other)})
    end
  end

  # GET /api/harness/gov-debug/char-status?iid=7&cid=42
  # A character's transit-relevant state for e2e assertions. 404s (as
  # :character_gone) when the agent process is dead — itself an
  # assertion target for the kill paths.
  def char_status(conn, %{"iid" => iid, "cid" => cid}) do
    with :ok <- dev_only(),
         {:ok, iid, cid} <- parse_ids(iid, cid) do
      result =
        try do
          Game.call(iid, :character, cid, :get_state)
        catch
          :exit, _ -> {:error, :character_gone}
        end

      case result do
        {:ok, character} ->
          queue_types =
            case character.actions do
              nil -> []
              actions -> actions.queue |> Queue.to_list() |> Enum.map(&Atom.to_string(&1.type))
            end

          json(conn, %{
            id: character.id,
            type: character.type,
            system: character.system,
            action_status: character.action_status,
            virtual_position: character.actions && character.actions.virtual_position,
            queue: queue_types,
            reaction: character.army && character.army.reaction
          })

        {:error, reason} ->
          conn |> put_status(404) |> json(%{error: inspect(reason)})
      end
    else
      {:error, :not_dev} -> conn |> put_status(404) |> json(%{error: :not_available})
      {:error, :invalid_params} -> conn |> put_status(400) |> json(%{error: :invalid_params})
    end
  end

  # POST /api/harness/gov-debug/char-op
  #   {"iid": 7, "pid": 12, "op": "add_actions", "character_id": 42,
  #    "actions": [{"type": "gateway_charge", "data": {...}}]}
  # Relays whitelisted CHARACTER-level player ops — the exact calls the
  # player channel makes, minus the socket. Includes the hostile-removal
  # simulators (assassinate/deactivate) the gateway e2e asserts against.
  @char_ops ~w(add_actions clear_actions update_reaction assassinate deactivate)

  def char_op(conn, %{"iid" => iid, "pid" => pid, "op" => op} = params) do
    with :ok <- dev_only(),
         {:ok, iid, pid} <- parse_ids(iid, pid),
         true <- op in @char_ops,
         {:ok, message} <- build_char_op(op, params) do
      case Game.call(iid, :player, pid, message) do
        :ok -> json(conn, %{ok: true})
        {:ok, _} -> json(conn, %{ok: true})
        {:error, reason} -> conn |> put_status(422) |> json(%{ok: false, error: inspect(reason)})
        # deactivate/assassinate reply with the updated player struct
        %{} -> json(conn, %{ok: true})
        other -> conn |> put_status(422) |> json(%{ok: false, error: inspect(other)})
      end
    else
      {:error, :not_dev} -> conn |> put_status(404) |> json(%{error: :not_available})
      {:error, :invalid_params} -> conn |> put_status(400) |> json(%{error: :invalid_params})
      _ -> conn |> put_status(400) |> json(%{error: :invalid_params})
    end
  end

  defp build_char_op("add_actions", %{"character_id" => cid, "actions" => actions})
       when is_integer(cid) and is_list(actions),
       do: {:ok, {:add_character_actions, cid, actions}}

  defp build_char_op("clear_actions", %{"character_id" => cid} = params) when is_integer(cid),
    do: {:ok, {:clear_character_actions, cid, Map.get(params, "index", 0)}}

  defp build_char_op("update_reaction", %{"character_id" => cid, "reaction" => reaction})
       when is_integer(cid) and is_binary(reaction) do
    case parse_atom(reaction) do
      {:ok, parsed} -> {:ok, {:update_reaction, cid, parsed}}
      :error -> {:error, :invalid_params}
    end
  end

  defp build_char_op("assassinate", %{"character_id" => cid}) when is_integer(cid),
    do: {:ok, {:assassinate_character, cid}}

  defp build_char_op("deactivate", %{"character_id" => cid}) when is_integer(cid),
    do: {:ok, {:deactivate_character, cid}}

  defp build_char_op(_op, _params), do: {:error, :invalid_params}

  # GET /api/harness/gov-debug/diplo-status?iid=6
  def diplo_status(conn, %{"iid" => iid}) do
    with :ok <- dev_only(),
         {iid, ""} <- Integer.parse(to_string(iid)),
         {:ok, diplomacy} <- Game.call(iid, :diplomacy, :master, :get_state) do
      json(conn, %{
        instance_id: iid,
        factions: diplomacy.factions,
        relations: diplomacy.relations,
        proposals: diplomacy.proposals,
        tension: diplomacy.tension,
        wars: diplomacy.wars
      })
    else
      {:error, :not_dev} -> conn |> put_status(404) |> json(%{error: :not_available})
      other -> conn |> put_status(422) |> json(%{error: inspect(other)})
    end
  end

  # POST /api/harness/gov-debug/diplo-action
  #   {"iid": 6, "kind": "conquest", "aggressor": 11, "victim": 12, "success": true}
  # Injects a hostile-action report exactly as the character-action
  # pipeline would emit it — lets the harness exercise tension and war
  # meters without playing out a real conquest.
  @diplo_kinds ~w(conquest bombardment pillage destabilize removal agent_removal sabotage fleet_destroyed)
  def diplo_action(conn, %{"iid" => iid, "kind" => kind, "aggressor" => a, "victim" => v} = params) do
    success = Map.get(params, "success", true)

    with :ok <- dev_only(),
         {:ok, iid, _} <- parse_ids(iid, iid),
         {:ok, a, v} <- parse_ids(a, v),
         true <- kind in @diplo_kinds and is_boolean(success),
         :ok <- Instance.Diplomacy.Diplomacy.report(iid, String.to_existing_atom(kind), a, v, success) do
      json(conn, %{reported: true, kind: kind, aggressor: a, victim: v, success: success})
    else
      {:error, :not_dev} -> conn |> put_status(404) |> json(%{error: :not_available})
      {:error, :invalid_params} -> conn |> put_status(400) |> json(%{error: :invalid_params})
      false -> conn |> put_status(400) |> json(%{error: :invalid_params})
      other -> conn |> put_status(422) |> json(%{error: inspect(other)})
    end
  end

  # POST /api/harness/gov-debug/op
  #   {"iid": 6, "fid": 11, "actor": 12, "op": "vote",
  #    "args": {"ballot_id": 3, "candidate_id": 12}}
  #
  # Relays a WHITELISTED player-level government op to the faction agent
  # — the exact tuples the faction channel sends, minus the socket (the
  # end-to-end harness has no authenticated websocket). Dev-only like
  # everything here; in prod the whole route family 404s.
  @ops ~w(nominate vote appoint by_election depose snap diplomacy set_withdraw_cap withdraw grant donate purchase_patent order_station cancel_station demolish_station gateway_link gateway_unlink)

  def op(conn, %{"iid" => iid, "fid" => fid, "actor" => actor, "op" => op} = params) do
    args = Map.get(params, "args", %{})

    with :ok <- dev_only(),
         {:ok, iid, fid} <- parse_ids(iid, fid),
         {actor, ""} <- Integer.parse(to_string(actor)),
         true <- op in @ops and is_map(args),
         {:ok, message} <- build_op(op, actor, args),
         reply <- Game.call(iid, :faction, fid, message) do
      case reply do
        :ok -> json(conn, %{ok: true})
        {:ok, _} -> json(conn, %{ok: true})
        {:error, reason} -> conn |> put_status(422) |> json(%{ok: false, error: inspect(reason)})
        other -> conn |> put_status(422) |> json(%{ok: false, error: inspect(other)})
      end
    else
      {:error, :not_dev} -> conn |> put_status(404) |> json(%{error: :not_available})
      {:error, :invalid_params} -> conn |> put_status(400) |> json(%{error: :invalid_params})
      _ -> conn |> put_status(400) |> json(%{error: :invalid_params})
    end
  end

  @seats %{"leader" => :leader, "economy" => :economy, "military" => :military}
  @snap_targets %{"cabinet" => :cabinet, "leader" => :leader, "crisis" => :crisis}
  @diplo_kinds_pact %{"non_aggression" => :non_aggression, "peace" => :peace}

  defp build_op("nominate", actor, %{"ballot_id" => b, "candidate_id" => c})
       when is_integer(b) and is_integer(c),
       do: {:ok, {:gov_nominate, actor, b, c}}

  defp build_op("vote", actor, %{"ballot_id" => b} = args) when is_integer(b) do
    payload =
      cond do
        is_integer(args["candidate_id"]) and is_number(args["pct"]) ->
          %{candidate_id: args["candidate_id"], pct: args["pct"]}

        is_integer(args["candidate_id"]) and is_integer(args["amount"]) ->
          %{candidate_id: args["candidate_id"], amount: args["amount"]}

        is_integer(args["candidate_id"]) ->
          %{candidate_id: args["candidate_id"]}

        args["choice"] in ["approve", "reject"] ->
          %{choice: String.to_existing_atom(args["choice"])}

        true ->
          nil
      end

    if payload, do: {:ok, {:gov_vote, actor, b, payload}}, else: {:error, :invalid_params}
  end

  defp build_op("appoint", actor, %{"seat" => seat, "appointee_id" => a}) when is_integer(a) do
    case Map.get(@seats, seat) do
      nil -> {:error, :invalid_params}
      seat_atom -> {:ok, {:gov_appoint, actor, seat_atom, a}}
    end
  end

  defp build_op("by_election", actor, %{"seat" => seat}) do
    case Map.get(@seats, seat) do
      nil -> {:error, :invalid_params}
      seat_atom -> {:ok, {:gov_by_election, actor, seat_atom}}
    end
  end

  defp build_op("depose", actor, %{"seat" => seat}) do
    case Map.get(@seats, seat) do
      nil -> {:error, :invalid_params}
      seat_atom -> {:ok, {:gov_depose, actor, seat_atom}}
    end
  end

  defp build_op("snap", actor, %{"target" => target}) do
    case Map.get(@snap_targets, target) do
      nil -> {:error, :invalid_params}
      target_atom -> {:ok, {:gov_snap, actor, target_atom}}
    end
  end

  defp build_op("diplomacy", actor, %{"action" => action} = args) do
    faction_id = args["faction_id"]
    proposal_id = args["proposal_id"]

    case action do
      "declare_war" when is_integer(faction_id) ->
        {:ok, {:gov_diplomacy, actor, {:declare_war, faction_id}}}

      "propose" when is_integer(faction_id) ->
        case Map.get(@diplo_kinds_pact, args["kind"]) do
          nil -> {:error, :invalid_params}
          kind -> {:ok, {:gov_diplomacy, actor, {:propose, faction_id, kind}}}
        end

      "accept" when is_integer(proposal_id) ->
        {:ok, {:gov_diplomacy, actor, {:accept, proposal_id}}}

      "reject" when is_integer(proposal_id) ->
        {:ok, {:gov_diplomacy, actor, {:reject, proposal_id}}}

      "break_pact" when is_integer(faction_id) ->
        {:ok, {:gov_diplomacy, actor, {:break_pact, faction_id}}}

      _ ->
        {:error, :invalid_params}
    end
  end

  defp build_op("set_withdraw_cap", actor, %{"pct" => pct}) when is_number(pct),
    do: {:ok, {:gov_set_withdraw_cap, actor, pct}}

  defp build_op("withdraw", actor, args),
    do: with_amounts(args, fn amounts -> {:gov_withdraw, actor, amounts} end)

  defp build_op("grant", actor, %{"player_id" => player_id} = args) when is_integer(player_id),
    do: with_amounts(args, fn amounts -> {:gov_grant, actor, player_id, amounts} end)

  defp build_op("donate", actor, args),
    do: with_amounts(args, fn amounts -> {:gov_donate, actor, amounts} end)

  defp build_op("purchase_patent", actor, %{"key" => key}) when is_binary(key) do
    case parse_atom(key) do
      {:ok, parsed} -> {:ok, {:gov_purchase_patent, actor, parsed}}
      :error -> {:error, :invalid_params}
    end
  end

  defp build_op("order_station", actor, %{"system_id" => sid, "key" => key, "anchor" => anchor})
       when is_integer(sid) and is_binary(key) and is_integer(anchor) do
    case parse_atom(key) do
      {:ok, parsed} -> {:ok, {:gov_order_station_building, actor, sid, parsed, anchor}}
      :error -> {:error, :invalid_params}
    end
  end

  defp build_op("cancel_station", actor, %{"system_id" => sid}) when is_integer(sid),
    do: {:ok, {:gov_cancel_station_building, actor, sid}}

  defp build_op("gateway_link", actor, %{"system_a" => a, "system_b" => b})
       when is_integer(a) and is_integer(b),
       do: {:ok, {:gov_gateway_link, actor, a, b}}

  defp build_op("gateway_unlink", actor, %{"system_id" => sid}) when is_integer(sid),
    do: {:ok, {:gov_gateway_unlink, actor, sid}}

  defp build_op("demolish_station", actor, %{"system_id" => sid, "building_id" => bid})
       when is_integer(sid) and is_integer(bid),
       do: {:ok, {:gov_demolish_station_building, actor, sid, bid}}

  defp build_op(_op, _actor, _args), do: {:error, :invalid_params}

  defp parse_atom(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end

  defp with_amounts(args, build) do
    amounts = %{
      credit: Map.get(args, "credit", 0),
      technology: Map.get(args, "technology", 0),
      ideology: Map.get(args, "ideology", 0)
    }

    if Enum.all?(Map.values(amounts), &(is_number(&1) and &1 >= 0)) and
         Enum.any?(Map.values(amounts), &(&1 > 0)),
       do: {:ok, build.(amounts)},
       else: {:error, :invalid_params}
  end

  defp dev_only do
    if Application.get_env(:rc, :environment) == :dev,
      do: :ok,
      else: {:error, :not_dev}
  end

  defp parse_ids(iid, fid) do
    with {iid, ""} <- Integer.parse(to_string(iid)),
         {fid, ""} <- Integer.parse(to_string(fid)) do
      {:ok, iid, fid}
    else
      _ -> {:error, :invalid_params}
    end
  end
end
