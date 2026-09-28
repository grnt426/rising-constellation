defmodule Portal.WaveController do
  @moduledoc """
  Dev harness for the Wave Defense MVP (docs/wave-defense.md).

      POST /api/harness/wave/start            boot a wave instance
      GET  /api/harness/wave/:iid/status      live readout (Wave.Status)
      POST /api/harness/wave/:iid/force_hire  run a hire cycle now
      POST /api/harness/wave/:iid/run         run one Warlord pass now
      POST /api/harness/wave/:iid/speed       {"multiplier": n} runtime speed cheat
      POST /api/harness/wave/:iid/dominion/:system_id  flip a rebel system to a dominion
      POST /api/harness/wave/:iid/place       mint an agent (and a fleet) for a human player
      POST /api/harness/wave/:iid/order       push an itinerary for a hand-placed agent

  `start` body (all optional):

      {"email": "user1@abc",              // register this account in the human faction
       "emails": ["user2@abc", …],        // and these, so the human side has several players
       "owner_email": "user1@abc",        // instance owner (default user1@abc)
       "human_faction": "tetrarchy",      // default: first faction on the map
       "scenario_id": 42,                 // default: the bundled two-sector test map
       "game_data": {...},                // or inline scenario data (wins over scenario_id)
       "game_metadata": {...},
       "win_points_target": 999,          // keep a dominant Rebellion from ending the game
       "knobs": {"hire_interval_ut": 5},  // merged over Wave.defaults/0
       "speedup": 100}                    // apply the speed cheat right after boot

  Gated twice: the harness pipeline's shared secret AND a non-prod environment.
  """
  use Portal, :controller

  def start(conn, params) do
    with :ok <- dev_only(conn) do
      opts =
        [
          owner_email: params["owner_email"],
          human_email: params["email"],
          human_emails: params["emails"],
          human_faction: params["human_faction"],
          scenario_id: params["scenario_id"],
          game_data: params["game_data"],
          game_metadata: params["game_metadata"],
          win_points_target: params["win_points_target"],
          knobs: params["knobs"]
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      case Wave.Boot.start(opts) do
        {:ok, summary} ->
          speedup = apply_speedup(summary.instance_id, params["speedup"])

          json(
            conn,
            summary
            |> Map.put(:speedup, speedup)
            |> Map.put(:status, Wave.Status.read(summary.instance_id))
          )

        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    end
  end

  # GET /api/harness/wave/profile?ms=3000 — where scheduler time went across a
  # sampling window, grouped by agent type (see Wave.Profile).
  def profile(conn, params) do
    with :ok <- dev_only(conn) do
      ms =
        case Integer.parse(to_string(params["ms"] || "3000")) do
          {n, _} -> n
          :error -> 3000
        end

      case params["stacks"] do
        # ?stacks=player:3 samples {iid, :player, 3}; ?stacks=busiest picks the
        # hottest process. Needs &iid= for a registry key.
        nil ->
          json(conn, Wave.Profile.sample(ms))

        "busiest" ->
          json(conn, Wave.Profile.stacks(nil, ms))

        spec ->
          with [type, id] <- String.split(spec, ":", parts: 2),
               {iid, ""} <- Integer.parse(to_string(params["iid"])),
               {:ok, type} <- safe_atom(type) do
            agent_id = if id == "master", do: :master, else: String.to_integer(id)
            json(conn, Wave.Profile.stacks({iid, type, agent_id}, ms))
          else
            _ -> conn |> put_status(400) |> json(%{error: "stacks=<type>:<id>&iid=<instance> or stacks=busiest"})
          end
      end
    end
  end

  defp safe_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  def status(conn, %{"iid" => iid}) do
    with :ok <- dev_only(conn), {:ok, iid} <- parse_id(conn, iid) do
      json(conn, Wave.Status.read(iid))
    end
  end

  # GET /api/harness/wave/:iid/events?kind=wave_siderian_resolved&limit=500 —
  # the instance's event log, newest first, payloads decoded. The Rebellion's
  # behaviour rows are the wave_* kinds (see RC.Instances.InstanceEvent).
  def events(conn, %{"iid" => iid} = params) do
    with :ok <- dev_only(conn), {:ok, iid} <- parse_id(conn, iid) do
      limit =
        case Integer.parse(to_string(params["limit"] || "500")) do
          {n, _} when n > 0 -> min(n, 5_000)
          _ -> 500
        end

      opts = if params["kind"], do: [limit: limit, kind: params["kind"]], else: [limit: limit]

      rows =
        iid
        |> RC.Instances.InstanceEventLog.list_for_instance(opts)
        |> Enum.map(fn event ->
          %{
            id: event.id,
            kind: event.kind,
            character_id: event.character_id,
            system_id: event.system_id,
            inserted_at: event.inserted_at,
            payload:
              case Jason.decode(event.payload || "") do
                {:ok, payload} -> payload
                _ -> event.payload
              end
          }
        end)

      json(conn, rows)
    end
  end

  # GET /api/harness/wave/:iid/galaxy?sector=1&status=inhabited_neutral&limit=20
  # — the map as ids, with the Rebellion's stored contact on each system, so a
  # test can pick exactly where to stand things and see what the Erased can
  # read from there.
  def galaxy(conn, %{"iid" => iid} = params) do
    with :ok <- dev_only(conn), {:ok, iid} <- parse_id(conn, iid), {:ok, galaxy} <- fetch(conn, iid, :galaxy) do
      contacts = rebel_contacts(iid)
      limit = int(params["limit"], 40)

      rows =
        galaxy.stellar_systems
        |> filter_by(params["sector"], &to_string(&1.sector_id))
        |> filter_by(params["status"], &to_string(&1.status))
        |> filter_by(params["faction"], &to_string(&1.faction))
        |> Enum.sort_by(& &1.id)
        |> Enum.take(limit)
        |> Enum.map(fn system ->
          %{
            id: system.id,
            name: system.name,
            sector_id: system.sector_id,
            status: system.status,
            faction: system.faction,
            owner: system.owner,
            contact: Map.get(contacts, system.id, 0)
          }
          |> Map.merge(if(params["detail"], do: system_detail(iid, system.id), else: %{}))
        end)

      json(conn, %{
        sectors: Enum.map(galaxy.sectors, &%{id: &1.id, name: &1.name, owner: &1.owner, adjacent: &1.adjacent}),
        systems: rows
      })
    end
  end

  # POST /api/harness/wave/:iid/informers {"system_id": 42, "count": 3} — hand
  # the Rebellion the contact an infiltration would have bought it. Lets a test
  # reach a chosen visibility tier directly instead of waiting out the Erased
  # that would earn it.
  def informers(conn, %{"iid" => iid} = params) do
    with :ok <- dev_only(conn),
         {:ok, iid} <- parse_id(conn, iid),
         {:ok, system_id} <- parse_id(conn, params["system_id"]),
         {:ok, warlord} <- fetch(conn, iid, :wave),
         {:ok, player} <- fetch(conn, iid, {:player, warlord.player_id}) do
      count = int(params["count"], 1)
      call = {:drop_informer, system_id, "harness", count}
      result = Game.call(iid, :faction, player.faction_id, call, 1, 10_000)

      json(conn, %{
        system_id: system_id,
        dropped: count,
        contact: Map.get(rebel_contacts(iid), system_id, 0),
        result: inspect(result)
      })
    end
  end

  # `?detail=1` adds what only the system agent knows — who is standing there,
  # what it would take to beat them, and whether the system is under siege.
  # One call per row, so it is opt-in.
  defp system_detail(iid, system_id) do
    case Game.call(iid, :stellar_system, system_id, :get_state, 1, 5_000) do
      {:ok, system} ->
        %{
          counter_intelligence: system.counter_intelligence.value,
          siege: system.siege && %{type: system.siege.type, besieger_id: system.siege.besieger_id},
          characters:
            Enum.map(system.characters, fn c ->
              %{id: c.id, type: c.type, name: c.name, level: c.level, protection: c.protection, cover: c.cover}
            end)
        }

      _ ->
        %{}
    end
  end

  defp rebel_contacts(iid) do
    with {:ok, %{player_id: player_id}} when is_integer(player_id) <- Game.call(iid, :wave, :master, :status, 1, 5_000),
         {:ok, player} <- Game.call(iid, :player, player_id, :get_state, 1, 5_000),
         {:ok, faction} <- Game.call(iid, :faction, player.faction_id, :get_state, 1, 5_000) do
      Map.new(faction.contacts, fn {id, contact} -> {id, contact.value} end)
    else
      _ -> %{}
    end
  end

  defp fetch(conn, iid, :wave) do
    case Game.call(iid, :wave, :master, :status, 1, 10_000) do
      {:ok, warlord} -> {:ok, warlord}
      other -> conn |> put_status(500) |> json(%{error: inspect(other)}) |> halt()
    end
  end

  defp fetch(conn, iid, :galaxy), do: fetch(conn, iid, {:galaxy, :master})

  defp fetch(conn, iid, {type, id}) do
    case Game.call(iid, type, id, :get_state, 1, 10_000) do
      {:ok, state} -> {:ok, state}
      other -> conn |> put_status(500) |> json(%{error: inspect(other)}) |> halt()
    end
  end

  defp filter_by(rows, nil, _project), do: rows
  defp filter_by(rows, value, project), do: Enum.filter(rows, &(project.(&1) == value))

  defp int(value, default) do
    case Integer.parse(to_string(value || "")) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  # POST /api/harness/wave/:iid/place — stand a hand-built agent in a system so
  # the Rebellion's Erased have something concrete to find. See Wave.Fixture.
  #
  #   {"player_id": 7, "type": "admiral", "system_id": 42, "level": 6,
  #    "name": "CMO #0001-0002",
  #    "specialization": "assassin", "skills": [0, 3, 1, 0, 0, 0],
  #    "ships": {"key": "fighter_1", "count": 5, "tile": 1}}
  def place(conn, %{"iid" => iid} = params) do
    with :ok <- dev_only(conn),
         {:ok, iid} <- parse_id(conn, iid),
         {:ok, player_id} <- resolve_player(conn, iid, params) do
      case Wave.Fixture.place_agent(iid, player_id, params) do
        {:ok, agent} ->
          ships =
            case params["ships"] do
              nil -> nil
              ships -> Wave.Fixture.grant_ships(iid, agent.id, ships) |> elem(1)
            end

          json(conn, %{player_id: player_id, agent: agent, ships: ships})

        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    end
  end

  # POST /api/harness/wave/:iid/order — {"player_id": 7, "character_id": 12,
  # "action": "conquest", "target": 42}. Lane hops then the action, exactly the
  # itinerary the Warlord pushes, so a placed Navarch can lay a real siege.
  def order(conn, %{"iid" => iid} = params) do
    with :ok <- dev_only(conn),
         {:ok, iid} <- parse_id(conn, iid),
         {:ok, player_id} <- resolve_player(conn, iid, params),
         {:ok, character_id} <- parse_id(conn, params["character_id"]),
         {:ok, target} <- parse_id(conn, params["target"]) do
      extra = if params["target_character"], do: %{"target_character" => params["target_character"]}, else: %{}

      case Wave.Fixture.order(iid, player_id, character_id, params["action"] || "jump", target, extra) do
        {:ok, result} -> json(conn, result)
        {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    end
  end

  # A player by id, or by the account email that owns it — whichever the caller
  # finds easier to hold on to between requests.
  defp resolve_player(conn, _iid, %{"player_id" => player_id}) when not is_nil(player_id),
    do: parse_id(conn, player_id)

  defp resolve_player(conn, iid, %{"email" => email}) when is_binary(email) do
    with {:ok, account} <- RC.Accounts.get_account_by_email(email),
         %{id: id} <- RC.Repo.get_by(RC.Accounts.Profile, account_id: account.id),
         {:ok, galaxy} <- Game.call(iid, :galaxy, :master, :get_state),
         true <- Map.has_key?(galaxy.players, id) do
      {:ok, id}
    else
      _ -> conn |> put_status(404) |> json(%{error: "no player for #{email} in instance #{iid}"}) |> halt()
    end
  end

  defp resolve_player(conn, _iid, _params),
    do: conn |> put_status(400) |> json(%{error: "player_id or email required"}) |> halt()

  def force_hire(conn, %{"iid" => iid}) do
    with :ok <- dev_only(conn), {:ok, iid} <- parse_id(conn, iid) do
      warlord_call(conn, iid, :force_hire)
    end
  end

  def run(conn, %{"iid" => iid}) do
    with :ok <- dev_only(conn), {:ok, iid} <- parse_id(conn, iid) do
      warlord_call(conn, iid, :run_now)
    end
  end

  # POST /api/harness/wave/:iid/speed {"multiplier": 200} — the runtime speed
  # cheat without the cheat channel's 50x ceiling, so a Legacy test game can
  # show a colonization round trip in minutes. Multiplies every tick factor in
  # the instance, the Warlord's included.
  def speed(conn, %{"iid" => iid} = params) do
    with :ok <- dev_only(conn), {:ok, iid} <- parse_id(conn, iid) do
      case apply_speedup(iid, params["multiplier"]) do
        nil -> conn |> put_status(400) |> json(%{error: "multiplier must be a positive number"})
        result -> json(conn, %{speedup: result})
      end
    end
  end

  # POST /api/harness/wave/:iid/dominion/:system_id — turn one of the
  # Rebellion's own systems into a dominion through the normal player call, so
  # the Rebel Dominion tree can be watched developing a dominion. The MVP has no
  # Siderians, so nothing else gives the bot a dominion to look at.
  def dominion(conn, %{"iid" => iid, "system_id" => system_id}) do
    with :ok <- dev_only(conn),
         {:ok, iid} <- parse_id(conn, iid),
         {:ok, system_id} <- parse_id(conn, system_id) do
      case Game.call(iid, :wave, :master, :status, 1, 10_000) do
        {:ok, %{player_id: player_id}} when is_integer(player_id) ->
          result =
            case Game.call(iid, :player, player_id, {:transform_system_to_dominion, system_id}, 1, 30_000) do
              :ok -> "ok"
              other -> inspect(other)
            end

          json(conn, %{result: result, status: Wave.Status.read(iid)})

        other ->
          conn |> put_status(500) |> json(%{error: inspect(other)})
      end
    end
  end

  # POST /api/harness/wave/:iid/stop — end a test run: stop every tick server
  # and mark the instance paused, the same pair the portal's Pause button runs.
  # A paused instance is restored on boot without its clock running.
  def stop(conn, %{"iid" => iid}) do
    with :ok <- dev_only(conn), {:ok, iid} <- parse_id(conn, iid) do
      case RC.Instances.get_instance(iid) do
        %{state: "running"} = instance ->
          stopped = Instance.Manager.call(iid, :stop)
          paused = RC.Instances.pause_instance(instance, instance.account_id)
          json(conn, %{stopped: inspect(stopped), paused: match?({:ok, _}, paused)})

        %{state: state} ->
          json(conn, %{stopped: false, state: state})

        nil ->
          conn |> put_status(404) |> json(%{error: "instance not found"})
      end
    end
  end

  # POST /api/harness/wave/:iid/resume — undo /stop: restart the tick servers
  # and mark the instance running, the portal's Resume pair.
  def resume(conn, %{"iid" => iid}) do
    with :ok <- dev_only(conn), {:ok, iid} <- parse_id(conn, iid) do
      case RC.Instances.get_instance(iid) do
        %{state: "paused"} = instance ->
          started = Instance.Manager.call(iid, :start)
          resumed = RC.Instances.resume_instance(instance, instance.account_id)
          json(conn, %{started: inspect(started), resumed: match?({:ok, _}, resumed)})

        # Not live after a server restart: rebuild from the latest snapshot and
        # mark it running — the portal's Restart button path.
        %{state: "not_running"} = instance ->
          restarted = RC.Instances.restart_instance_from_snapshot(instance)

          marked =
            if restarted == {:ok, :restarted},
              do: match?({:ok, _}, RC.Instances.restart_instance(instance, instance.account_id)),
              else: false

          json(conn, %{restarted: inspect(restarted), running: marked})

        %{state: state} ->
          json(conn, %{started: false, state: state})

        nil ->
          conn |> put_status(404) |> json(%{error: "instance not found"})
      end
    end
  end

  defp apply_speedup(iid, multiplier) when is_number(multiplier) and multiplier > 0 do
    inspect(Instance.Manager.call(iid, {:cheat_set_speedup, multiplier}))
  end

  defp apply_speedup(_iid, _multiplier), do: nil

  defp warlord_call(conn, iid, message) do
    case Game.call(iid, :wave, :master, message, 1, 30_000) do
      {:ok, summary} -> json(conn, %{warlord: summary, status: Wave.Status.read(iid)})
      other -> conn |> put_status(500) |> json(%{error: inspect(other)})
    end
  end

  defp dev_only(conn) do
    if Application.get_env(:rc, :environment) in [:dev, :test] do
      :ok
    else
      conn |> put_status(403) |> json(%{error: "dev_only"}) |> halt()
    end
  end

  defp parse_id(conn, iid) do
    case Integer.parse(to_string(iid)) do
      {id, ""} -> {:ok, id}
      _ -> conn |> put_status(400) |> json(%{error: "bad_instance_id"}) |> halt()
    end
  end
end
