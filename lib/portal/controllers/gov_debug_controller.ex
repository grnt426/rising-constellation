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
        withdraw_cap_pct: Map.get(government, :withdraw_cap_pct, 0)
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
  @ops ~w(nominate vote appoint by_election depose snap diplomacy set_withdraw_cap withdraw grant donate)

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

  defp build_op(_op, _actor, _args), do: {:error, :invalid_params}

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
