defmodule Portal.DevFixtureController do
  @moduledoc """
  Dev-only harness endpoint that fabricates a small two-faction game with
  real opposing agents parked in the caller's starting system — for
  exercising the system-view agent display (fan, squadrons, hover cards,
  per-agent action buttons) without orchestrating a real multiplayer game.

      POST /api/harness/dev/agent-fixture
      body: {"email": "user1@abc"}   (optional; defaults to user1@abc)

  The agents are engine-real: each one goes through the same
  `{:convert_character, ...}` player call the seduction action uses, so it
  lives in its owner's roster, has a live `Instance.Character.Agent`, and is
  a valid target for fight / removal / sabotage / seduction.

  Option `"empire"` (`true`, or `{"destabilize": false}` to skip the
  stability drop) grows the caller into a small empire for help-manual
  screenshots, before any agent is placed. Every step is a real game path:
  the `agent` → `system_1` → `dominion_1` Lexes are bought, slotted into
  bought Lex slots and applied (`{:update_policies, _}`), which lifts the
  System Limit to 2 and the Dominion Limit to 3; the nearest takeable
  uninhabited system is claimed (`{:claim_system, _}`, as colonization
  does); the nearest takeable autonomous system becomes a dominion
  (`{:claim_dominion, _}`, as a successful Control does); and the second
  owned system gets a Destabilization penalty (`{:add_happiness_penalty,
  :encourage_hate, _}`, as Destabilize does) deep enough to leave the
  Normal population status. Home stays untouched, so its breakdowns carry
  no "Insufficient stability" rows. The response gains an `empire` block:

      %{home, owned2, dominion, autonomous, uninhabited, destabilized,
        population_status, systems, dominions, lexes, max_systems,
        max_dominions}

  `autonomous` and `uninhabited` are the nearest remaining systems of that
  status (not claimed). Each gets one of the player's common Siderians
  parked in it, since an own agent is what gives visibility on a foreign
  system. Without the option `empire` is `null`.

  `{"buildings": true}` inside `empire` (Legacy or Tactic content) also
  builds up home's planet, the habitable planet holding the
  infrastructure building, for the Buildings screenshots. It grants the
  exact credit and technology needed, buys the patents
  (`{:purchase_patent, _}`, ancestors first), then:

    * sets the infrastructure building to level 2
    * puts a Residential District level 1, idle (its Upgrade button shows),
      and a damaged Delta Polytech level 1 (its Repair button shows; it is
      Limited, so the build menu greys out a second one) on the first two
      free tiles. Real paths can't finish or damage a building on demand,
      so these go through the dev-only `{:dev_put_building, ...}` call of
      `Instance.StellarSystem.Agent`
    * orders a Floating Gardens, then a Residential District, on the next
      two free tiles through the player agent (`{:order_building, ...}`),
      so the construction queue holds two real orders

  At least one tile stays free for the build menu. `empire.buildings`
  holds the body uid, the tile of each building, the free tiles, the
  bought patents and the queue.

  `{"schools": true}` inside `empire` puts a finished Delta Polytech and an
  Orb-INTEL (level 2, or 1 at Flash speed, whose buildings have one level)
  on two free tiles of home's planet (the same dev-only call), for the
  agent-training flows (docs/agent-training.md): one seat for any agent of
  the player, one per level for Erased. The player's own agents are given
  the experience that takes them to the level a university asks
  (`university_min_level`), the way a Training Center gives it. `empire.schools`
  holds the body uid and the tile and level of each building.

  `{"research": true}` inside `empire` (Legacy or Tactic content) sets up the
  patent and lex panels for the Patents & lexes screenshots, through the
  same player-agent calls the panels use, with the exact technology and
  ideology granted first:

    * buys patents in three branches (`@research_patents` and their
      ancestors); the fourth stays unbought, so its tab shows locked patents
    * buys the lexes `@research_lexes` (bought, not active) and one more
      Lex slot, so a change can add one of them
    * clears the wait the empire's own lex change started
      (`:cheat_clear_policies_cooldown`), so the panel can stage a change

  `empire.research` lists the bought patents and lexes and the slot count.

  Gated twice: the harness pipeline's shared secret AND `:environment ==
  :dev` — it must never respond on a prod node.
  """
  use Portal, :controller

  require Logger

  alias Instance.Character.Character, as: GameCharacter
  alias RC.Accounts
  alias RC.Accounts.Profile

  # Seeded dev accounts that lend their profiles to the hostile faction.
  @puppets ["user2@abc", "user3@abc"]

  # Hold every action start/finish hook of instance `iid` for `ms` before
  # it runs (0 lifts it), so E2E specs can hit the window where a
  # character's queue is locked on demand. Read by
  # Instance.ActionOrchestrator.Agent.harness_delay/1.
  def orchestrator_delay(conn, %{"instance_id" => iid, "ms" => ms})
      when is_integer(iid) and is_integer(ms) and ms >= 0 and ms <= 10_000 do
    if Application.get_env(:rc, :environment) == :dev do
      if ms == 0,
        do: :persistent_term.erase({Instance.ActionOrchestrator.Agent, :harness_delay, iid}),
        else: :persistent_term.put({Instance.ActionOrchestrator.Agent, :harness_delay, iid}, ms)

      json(conn, %{instance_id: iid, ms: ms})
    else
      conn |> put_status(404) |> json(%{error: :not_available})
    end
  end

  def orchestrator_delay(conn, _params), do: conn |> put_status(400) |> json(%{error: :invalid_params})

  @doc """
  GET /api/harness/dev/top?ms=3000&n=15 — the processes that did the most
  work (reductions) over the next `ms` milliseconds, named the way the game
  registers them (`{instance_id, type, agent_id}`), for "what is burning
  CPU?" without a remote shell (the dev server isn't a distributed node).
  """
  def top(conn, params) do
    if Application.get_env(:rc, :environment) == :dev do
      ms = params |> Map.get("ms", "3000") |> to_int(3000) |> min(30_000) |> max(100)
      n = params |> Map.get("n", "15") |> to_int(15) |> min(100) |> max(1)

      before = Map.new(Process.list(), &{&1, reductions(&1)})
      Process.sleep(ms)

      rows =
        Process.list()
        |> Enum.map(&{&1, reductions(&1) - Map.get(before, &1, 0)})
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(n)
        |> Enum.map(fn {pid, delta} -> describe(pid, delta) end)

      json(conn, %{ms: ms, total_reductions: Enum.sum(Enum.map(rows, & &1.reductions)), top: rows})
    else
      conn |> put_status(404) |> json(%{error: :not_available})
    end
  end

  defp reductions(pid) do
    case Process.info(pid, :reductions) do
      {:reductions, r} -> r
      nil -> 0
    end
  end

  defp describe(pid, delta) do
    info = Process.info(pid, [:registered_name, :current_function, :message_queue_len, :dictionary]) || []
    dict = Keyword.get(info, :dictionary, [])

    queue = Keyword.get(info, :message_queue_len) || 0

    %{
      pid: inspect(pid),
      reductions: delta,
      name:
        case Horde.Registry.keys(Game.Registry, pid) do
          [key | _] -> inspect(key)
          [] -> inspect(Keyword.get(info, :registered_name) || Keyword.get(dict, :"$initial_call"))
        end,
      current: inspect(Keyword.get(info, :current_function)),
      queue: queue,
      # what a backed-up mailbox is full of: message kinds among the first 500
      queued: if(queue > 100, do: queued_kinds(pid), else: %{})
    }
  end

  defp queued_kinds(pid) do
    case Process.info(pid, :messages) do
      {:messages, messages} ->
        messages |> Enum.take(500) |> Enum.frequencies_by(&message_kind/1)

      nil ->
        %{}
    end
  end

  defp message_kind({:"$gen_cast", request}), do: "cast " <> request_kind(request)
  defp message_kind({:"$gen_call", _from, request}), do: "call " <> request_kind(request)
  defp message_kind(message), do: "info " <> request_kind(message)

  defp request_kind(request) when is_tuple(request) and tuple_size(request) > 0, do: inspect(elem(request, 0))
  defp request_kind(request), do: request |> inspect() |> String.slice(0, 40)

  defp to_int(value, default) do
    case Integer.parse(to_string(value)) do
      {i, _} -> i
      :error -> default
    end
  end

  def agent_fixture(conn, params) do
    if Application.get_env(:rc, :environment) == :dev do
      case build(
             params["email"] || "user1@abc",
             params["grant"],
             params["features"],
             params["own_admirals"] || 1,
             params["armada_layout"] || %{},
             params["speed"],
             params["empire"]
           ) do
        {:ok, summary} ->
          json(conn, summary)

        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    else
      conn |> put_status(403) |> json(%{error: "dev_only"})
    end
  end

  @doc """
  POST /api/harness/dev/gateway-fixture — the gateway-e2e stage: a
  two-faction instance where the MYRMEZIR side has two players (user2,
  user3), each owning a starting system (the two future gateway
  endpoints), with three myrmezir agents (2 navarchs + 1 siderian)
  parked on user2's system as travelers. user1's tetrarchy exists so
  the galaxy has an opposing faction. Returns every id the e2e needs.
  """
  def gateway_fixture(conn, params) do
    if Application.get_env(:rc, :environment) == :dev do
      case build_gateway_stage(params["gov_disabled"] == true) do
        {:ok, summary} -> json(conn, summary)
        {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    else
      conn |> put_status(403) |> json(%{error: "dev_only"})
    end
  end

  defp build_gateway_stage(gov_disabled \\ false) do
    with {:ok, account} <- Accounts.get_account_by_email("user1@abc") do
      profile = ensure_profile(account)
      [p2, p3] = Enum.map(@puppets, &ensure_puppet/1)

      game_data =
        "test/support/scenario_game_data.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.merge(%{"time_limit" => 100_000, "victory_points" => 999_999})

      game_metadata =
        "test/support/scenario_game_metadata.json" |> File.read!() |> Jason.decode!()

      {:ok, scenario} =
        %RC.Scenarios.Scenario{}
        |> RC.Scenarios.Scenario.changeset(%{
          game_data: game_data,
          game_metadata: game_metadata,
          is_map: false
        })
        |> RC.Repo.insert()

      instance_attrs = %{
        "name" => "Gateway fixture — #{DateTime.utc_now() |> DateTime.truncate(:second)}",
        "description" => "Dev fixture: two same-faction systems for gateway transit e2e",
        "opening_date" => DateTime.to_iso8601(DateTime.utc_now()),
        "registration_type" => "pre_registration",
        "game_type" => "private",
        "public" => false,
        "start_setting" => "auto",
        "factions" => [
          %{"key" => "tetrarchy", "capacity" => 1},
          %{"key" => "myrmezir", "capacity" => 2}
        ]
      }

      # An EXPLICIT false is the only creation-time off-switch — it beats
      # the dev :government_all_speeds flag, which is what lets the e2e
      # prove the station/gateway surfaces are gated in no-gov games.
      instance_attrs =
        if gov_disabled,
          do: Map.put(instance_attrs, "faction_gov_enabled", false),
          else: instance_attrs

      {:ok, %{instance: instance}} = RC.Instances.create_instance(instance_attrs, scenario, account.id)
      {:ok, _} = RC.Instances.publish_instance(instance, account.id)

      tetrarchy = Enum.find(instance.factions, &(&1.faction_ref == "tetrarchy"))
      myrmezir = Enum.find(instance.factions, &(&1.faction_ref == "myrmezir"))

      {:ok, _} = RC.Registrations.register_profile(tetrarchy, profile)
      {:ok, _} = RC.Registrations.register_profile(myrmezir, p2)
      {:ok, _} = RC.Registrations.register_profile(myrmezir, p3)

      loaded = RC.Instances.get_instance_with_registration(instance.id)

      with {:ok, :instantiated} <- Instance.Manager.create_from_model(loaded, nil),
           {:ok, _} <- RC.Instances.start_instance(loaded, account.id),
           {:ok, :started, _} <- Instance.Manager.call(instance.id, :start),
           {:ok, player2} <- Game.call(instance.id, :player, p2.id, :get_state),
           {:ok, player3} <- Game.call(instance.id, :player, p3.id, :get_state) do
        system_a = hd(player2.stellar_systems)
        system_b = hd(player3.stellar_systems)

        # travelers on system A: two navarchs (transit + busy-check) and
        # one siderian (non-admiral traveler)
        for {type, rank} <- [admiral: :remarkable, admiral: :common, speaker: :common] do
          place(instance.id, p2.id, type, rank, system_a.id)
        end

        {:ok, player2} = Game.call(instance.id, :player, p2.id, :get_state)

        characters =
          Enum.map(player2.characters, fn c -> %{id: c.id, type: c.type, name: c.name} end)

        Logger.info("[gateway-fixture] instance=#{instance.id} A=#{system_a.id} B=#{system_b.id}")

        {:ok,
         %{
           instance_id: instance.id,
           myrmezir_faction_id: myrmezir.id,
           tetrarchy_faction_id: tetrarchy.id,
           p2: %{id: p2.id, system: %{id: system_a.id, name: system_a.name}},
           p3: %{id: p3.id, system: %{id: system_b.id, name: system_b.name}},
           characters: characters
         }}
      end
    end
  end

  # `armada_layout` (optional): %{"own" => [2, 2], "friendly" => [3],
  # "hostile" => [2]} — group sizes to pre-form as armadas. Own groups
  # consume the caller's admirals in id order (size own_admirals to
  # cover their sum). Friendly groups mint fresh navarchs for puppet 2
  # registered to the CALLER's faction (only when friendly groups are
  # requested — otherwise both puppets stay hostile, exactly as
  # before). Hostile groups mint fresh navarchs for a myrmezir puppet.
  defp build(email, grant, features, own_admirals, armada_layout, speed, empire) do
    with {:ok, account} <- Accounts.get_account_by_email(email) do
      profile = ensure_profile(account)
      set_features(account, features)
      [p2, p3] = Enum.map(@puppets, &ensure_puppet/1)

      # The test-suite scenario: two factions (tetrarchy / myrmezir), each
      # owning a sector. Lifted limits so the fixture neither times out nor
      # ends by victory points while it sits around waiting to be tested.
      # `speed` (optional: "fast" | "medium" | "slow") overrides the
      # scenario's tick rate — e2e flows that assert speed-conditional UI
      # (e.g. the Legacy-only income-per-hour display) need a :slow world.
      game_data =
        "test/support/scenario_game_data.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.merge(%{"time_limit" => 100_000, "victory_points" => 999_999})

      game_data =
        if speed in ["fast", "medium", "slow"],
          do: Map.put(game_data, "speed", speed),
          else: game_data

      game_metadata =
        "test/support/scenario_game_metadata.json" |> File.read!() |> Jason.decode!()

      {:ok, scenario} =
        %RC.Scenarios.Scenario{}
        |> RC.Scenarios.Scenario.changeset(%{
          game_data: game_data,
          game_metadata: game_metadata,
          is_map: false
        })
        |> RC.Repo.insert()

      instance_attrs = %{
        "name" => "Agent fixture — #{DateTime.utc_now() |> DateTime.truncate(:second)}",
        "description" => "Dev fixture: opposing agents in #{profile.name}'s starting system",
        "opening_date" => DateTime.to_iso8601(DateTime.utc_now()),
        "registration_type" => "pre_registration",
        "game_type" => "private",
        "public" => false,
        "start_setting" => "auto",
        # The fixture's caller is the instance creator, so E2E runs can
        # use the creator-tier cheats (set_speed) to compress real
        # production/travel/colonization timelines into test budgets.
        "cheats_enabled" => true,
        "factions" => [
          %{"key" => "tetrarchy", "capacity" => 2},
          %{"key" => "myrmezir", "capacity" => 2}
        ]
      }

      friendly_groups = armada_groups(armada_layout, "friendly")
      hostile_groups = armada_groups(armada_layout, "hostile")
      own_groups = armada_groups(armada_layout, "own")

      {:ok, %{instance: instance}} = RC.Instances.create_instance(instance_attrs, scenario, account.id)
      {:ok, _} = RC.Instances.publish_instance(instance, account.id)

      tetrarchy = Enum.find(instance.factions, &(&1.faction_ref == "tetrarchy"))
      myrmezir = Enum.find(instance.factions, &(&1.faction_ref == "myrmezir"))

      # friendly armadas need a same-faction neighbour: puppet 2 defects
      # to the caller's faction only when the layout asks for one
      p3_faction = if friendly_groups == [], do: myrmezir, else: tetrarchy

      {:ok, _} = RC.Registrations.register_profile(tetrarchy, profile)
      {:ok, _} = RC.Registrations.register_profile(myrmezir, p2)
      {:ok, _} = RC.Registrations.register_profile(p3_faction, p3)

      loaded = RC.Instances.get_instance_with_registration(instance.id)

      with {:ok, :instantiated} <- Instance.Manager.create_from_model(loaded, nil),
           {:ok, _} <- RC.Instances.start_instance(loaded, account.id),
           {:ok, :started, _} <- Instance.Manager.call(instance.id, :start),
           {:ok, player} <- Game.call(instance.id, :player, profile.id, :get_state),
           # Before any agent is placed: the Lex swap inside checks the
           # player's agent counts against its agent limits.
           {:ok, empire_summary} <- build_empire(instance.id, profile.id, hd(player.stellar_systems).id, empire) do
        # `player` is the pre-empire snapshot, so its head is still home
        system = hd(player.stellar_systems)

        # Own hand: one agent of each type on board, so every kind of
        # action button has a source to be selected. `own_admirals`
        # (default 1) adds extra common navarchs — armada E2E needs
        # 2-3 own admirals co-located to form/join/break.
        extra_admirals = List.duplicate({:admiral, :common}, max(own_admirals - 1, 0))

        for {type, rank} <- [admiral: :remarkable, spy: :common, speaker: :common] ++ extra_admirals do
          place(instance.id, profile.id, type, rank, system.id)
        end

        # with schools to send them to: the level a university asks
        :ok = maybe_season_agents(instance.id, profile.id, is_map(empire) and Map.get(empire, "schools") == true)

        # Puppet 1: a four-agent squadron — exercises the cluster badge,
        # the unfurl, and the action buttons inside the fan. Mostly
        # always-visible types; the one spy starts discovered (cover 0)
        # but will fade from view as its cover rebuilds.
        for {type, rank} <- [admiral: :exceptional, admiral: :common, speaker: :remarkable, spy: :common] do
          place(instance.id, p2.id, type, rank, system.id)
        end

        # Puppet 2: a lone hostile navarch — exercises the single-badge path.
        place(instance.id, p3.id, :admiral, :remarkable, system.id)

        # Optional starting-resource grant for E2E flows that need to walk
        # the patent tree / afford fleets without playing out the opening
        # economy first. Same player call the cheat channel's
        # grant_resources uses; dev + harness-secret gated like the rest
        # of this endpoint.
        grant_resources(instance.id, profile.id, grant)

        # pre-formed armadas, through the same player-agent calls the
        # channel uses
        own_armadas = form_own_armadas(instance.id, profile.id, own_groups)
        friendly_armadas = Enum.map(friendly_groups, &place_armada(instance.id, p3.id, system.id, &1))
        hostile_armadas = Enum.map(hostile_groups, &place_armada(instance.id, p2.id, system.id, &1))

        Logger.info("[dev-fixture] instance=#{instance.id} system=#{system.id} (#{system.name})")

        {:ok,
         %{
           instance_id: instance.id,
           system: %{id: system.id, name: system.name},
           enter_url: "/portal/instance/#{instance.id}",
           agents: %{own: 3 + length(extra_admirals), hostile_squadron: 4, hostile_lone: 1},
           armadas: %{own: own_armadas, friendly: friendly_armadas, hostile: hostile_armadas},
           empire: empire_summary
         }}
      end
    end
  end

  # ---------------------------------------------------------------- empire

  # Lexes slotted by the `empire` option. At every speed `system_1` gives
  # +1 System Limit and `dominion_1` +3 Dominion Limit. `agent` is the
  # tree root; slotting it too keeps the agent limits at or above the
  # player's starting agent, which update_policies checks.
  @empire_lexes [:agent, :system_1, :dominion_1]

  # How far below zero the destabilized system's stability is pushed:
  # -15 is mid "demonstration" band (-10..-20), so the penalty's slow
  # decay during a capture run doesn't bring the system back to Normal.
  @empire_destabilize_depth 15

  defp build_empire(_instance_id, _profile_id, _home_id, empire) when empire in [nil, false], do: {:ok, nil}

  defp build_empire(instance_id, profile_id, home_id, true), do: build_empire(instance_id, profile_id, home_id, %{})

  defp build_empire(instance_id, profile_id, home_id, %{} = opts) do
    destabilize? = Map.get(opts, "destabilize", true) != false
    buildings? = Map.get(opts, "buildings", false) == true
    research? = Map.get(opts, "research", false) == true
    schools? = Map.get(opts, "schools", false) == true

    with :ok <- slot_empire_lexes(instance_id, profile_id),
         {:ok, galaxy} <- Game.call(instance_id, :galaxy, :master, :get_state),
         {:ok, player} <- Game.call(instance_id, :player, profile_id, :get_state),
         {:ok, nearby} <- systems_by_distance(galaxy, home_id),
         in_reach = &takeable?(instance_id, &1.id, player.faction),
         anywhere = fn _system -> true end,
         {:ok, owned2_id} <- pick_system(nearby, :uninhabited, [], in_reach),
         {:ok, _} <- claim_and_confirm(instance_id, profile_id, {:claim_system, owned2_id}, :stellar_systems),
         {:ok, dominion_id} <- pick_system(nearby, :inhabited_neutral, [], in_reach),
         {:ok, _} <- claim_and_confirm(instance_id, profile_id, {:claim_dominion, dominion_id}, :dominions),
         # `nearby` is the pre-claim galaxy snapshot: exclude the claimed ids
         {:ok, autonomous_id} <- pick_system(nearby, :inhabited_neutral, [dominion_id], anywhere),
         {:ok, uninhabited_id} <- pick_system(nearby, :uninhabited, [owned2_id], anywhere),
         # Scouts: an own agent in a system gives the faction visibility 2
         # on it (Faction.resolve_system_visibility/2), enough for the SPA
         # to show that system's bodies and state instead of "no data".
         :ok <- place(instance_id, profile_id, :speaker, :common, autonomous_id),
         :ok <- place(instance_id, profile_id, :speaker, :common, uninhabited_id),
         {:ok, population_status} <- maybe_destabilize(instance_id, owned2_id, destabilize?),
         {:ok, buildings} <- maybe_place_buildings(instance_id, profile_id, home_id, buildings?),
         {:ok, research} <- maybe_research(instance_id, profile_id, research?),
         {:ok, schools} <- maybe_place_schools(instance_id, home_id, schools?),
         {:ok, player} <- Game.call(instance_id, :player, profile_id, :get_state) do
      Logger.info(
        "[dev-fixture] empire home=#{home_id} owned2=#{owned2_id} dominion=#{dominion_id} " <>
          "autonomous=#{autonomous_id} uninhabited=#{uninhabited_id} owned2_status=#{population_status}"
      )

      {:ok,
       %{
         home: home_id,
         owned2: owned2_id,
         dominion: dominion_id,
         autonomous: autonomous_id,
         uninhabited: uninhabited_id,
         destabilized: if(destabilize?, do: owned2_id),
         population_status: population_status,
         systems: Enum.map(player.stellar_systems, & &1.id),
         dominions: Enum.map(player.dominions, & &1.id),
         lexes: player.policies,
         max_systems: player.max_systems.value,
         max_dominions: player.max_dominions.value,
         buildings: buildings,
         research: research,
         schools: schools
       }}
    else
      {:error, _} = error -> error
      other -> {:error, {:empire, other}}
    end
  end

  defp build_empire(_instance_id, _profile_id, _home_id, other), do: {:error, {:bad_empire_option, other}}

  # Buy the Lexes (ancestors first), buy the missing Lex slots, then slot
  # them, through the same player-agent calls the Lex screen uses. The
  # exact ideology price is granted first (same formulas as
  # Player.purchase_doctrine/2 and Player.purchase_policy_slot/1), so the
  # player's own ideology is unchanged afterwards.
  defp slot_empire_lexes(instance_id, profile_id) do
    with {:ok, player} <- Game.call(instance_id, :player, profile_id, :get_state) do
      c = Data.Querier.one(Data.Game.Constant, instance_id, :main)

      to_buy =
        @empire_lexes
        |> Enum.flat_map(&ancestry(Data.Game.Doctrine, instance_id, &1))
        |> Enum.uniq()
        |> Enum.reject(&(&1 in player.doctrines))

      policies = Enum.uniq(player.policies ++ @empire_lexes)
      slots = max(length(policies) - player.max_policies, 0)

      doctrine_cost =
        to_buy
        |> Enum.with_index(length(player.doctrines))
        |> Enum.map(fn {key, n} ->
          Data.Querier.one(Data.Game.Doctrine, instance_id, key).cost * (1 + n * c.doctrine_level_price_increase)
        end)
        |> Enum.sum()

      slot_cost =
        if slots == 0 do
          0
        else
          Enum.reduce(0..(slots - 1), 0, fn k, acc ->
            price = round(:math.pow(2, player.max_policies - 1 + k)) * c.initial_policy_slot_cost
            acc + min(price, c.policy_slot_maximum_cost)
          end)
        end

      grant = %{credit: 0, technology: 0, ideology: ceil(doctrine_cost + slot_cost) + 1}
      call = &Game.call(instance_id, :player, profile_id, &1)

      with :ok <- call.({:cheat, :grant_resources, grant}),
           :ok <- each_ok(to_buy, &call.({:purchase_doctrine, &1})),
           :ok <- each_ok(List.duplicate(:policy_slot, slots), fn _ -> call.(:purchase_policy_slot) end),
           :ok <- call.({:update_policies, policies}) do
        :ok
      else
        {:error, _} = error -> error
        other -> {:error, {:slot_empire_lexes, other}}
      end
    end
  end

  # [root, ..., key] of a Lex (Data.Game.Doctrine) or a patent; an unknown
  # key is left for the purchase call to refuse
  defp ancestry(schema, instance_id, key) do
    case Data.Querier.one(schema, instance_id, key) do
      %{ancestor: parent} when not is_nil(parent) -> ancestry(schema, instance_id, parent) ++ [key]
      _ -> [key]
    end
  end

  # ---------------------------------------------------------------- research

  # A patent deep in three Legacy/Tactic branches; buying it buys its chain.
  # Moons and Asteroids stays unbought, so its tab shows locked patents right
  # after the first available one, left of the patent panel's dock.
  @research_patents [:open_industries, :dome_pop, :fighter_2]
  # Bought but not active, in three tabs. Public Relations (speaker_2, with
  # its chain) raises the Siderian Limit, so a change that adds it is
  # accepted although the empire's three Siderians exceed the limit.
  @research_lexes [:admiral_1, :speaker_2, :credit_1]

  defp maybe_research(_instance_id, _profile_id, false), do: {:ok, nil}

  defp maybe_research(instance_id, profile_id, true) do
    call = &Game.call(instance_id, :player, profile_id, &1)

    with {:ok, player} <- call.(:get_state),
         :ok <- research_in_content(instance_id),
         c = Data.Querier.one(Data.Game.Constant, instance_id, :main),
         patents = research_to_buy(Data.Game.Patent, instance_id, @research_patents, player.patents),
         lexes = research_to_buy(Data.Game.Doctrine, instance_id, @research_lexes, player.doctrines),
         mult = Instance.Mutators.cost_multiplier(instance_id, :patent),
         technology = research_price(Data.Game.Patent, instance_id, patents, length(player.patents), c.patent_level_price_increase) * mult,
         ideology = research_price(Data.Game.Doctrine, instance_id, lexes, length(player.doctrines), c.doctrine_level_price_increase),
         slot = min(round(:math.pow(2, player.max_policies - 1)) * c.initial_policy_slot_cost, c.policy_slot_maximum_cost),
         grant = %{credit: 0, technology: ceil(technology) + 1, ideology: ceil(ideology + slot) + 1},
         :ok <- call.({:cheat, :grant_resources, grant}),
         :ok <- each_ok(patents, &call.({:purchase_patent, &1})),
         :ok <- each_ok(lexes, &call.({:purchase_doctrine, &1})),
         :ok <- call.(:purchase_policy_slot),
         :ok <- call.(:cheat_clear_policies_cooldown),
         {:ok, player} <- call.(:get_state) do
      Logger.info("[dev-fixture] research patents=#{inspect(patents)} lexes=#{inspect(lexes)} slots=#{player.max_policies}")
      {:ok, %{patents: player.patents, lexes: player.doctrines, active: player.policies, slots: player.max_policies}}
    else
      {:error, _} = error -> error
      other -> {:error, {:research, other}}
    end
  end

  defp research_in_content(instance_id) do
    missing =
      Enum.filter(@research_patents, &is_nil(Data.Querier.one(Data.Game.Patent, instance_id, &1))) ++
        Enum.filter(@research_lexes, &is_nil(Data.Querier.one(Data.Game.Doctrine, instance_id, &1)))

    if missing == [], do: :ok, else: {:error, {:research, :not_in_this_speed, missing}}
  end

  defp research_to_buy(schema, instance_id, keys, owned) do
    keys
    |> Enum.flat_map(&ancestry(schema, instance_id, &1))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in owned))
  end

  # Player.purchase_patent/2 and purchase_doctrine/2: each purchase costs
  # base × (1 + owned × increase), owned counting the earlier purchases.
  defp research_price(schema, instance_id, keys, owned, increase) do
    keys
    |> Enum.with_index(owned)
    |> Enum.map(fn {key, n} -> Data.Querier.one(schema, instance_id, key).cost * (1 + n * increase) end)
    |> Enum.sum()
  end

  # ---------------------------------------------------------------- buildings

  # The `buildings` sub-option's cast, all Legacy/Tactic keys (Flash has
  # no hab_open or monument_open). The infrastructure building is whatever
  # stands on tile 1 of home's inhabited planet (infra_open on the
  # starter layout).
  @buildings_infra_level 2
  # Residential District: no patent, idle, so its Upgrade button shows
  @buildings_idle :hab_open
  # Delta Polytech: Limited (one per body), damaged, so its Repair button
  # shows and the build menu greys out a second one
  @buildings_damaged :university_open
  # Floating Gardens (1 200 production at Legacy, about 12 ticks at home's
  # 100 production), then a Residential District (30)
  @buildings_queued [:monument_open, :hab_open]

  defp maybe_place_buildings(_instance_id, _profile_id, _home_id, false), do: {:ok, nil}

  defp maybe_place_buildings(instance_id, profile_id, home_id, true) do
    keys = [@buildings_idle, @buildings_damaged | @buildings_queued]
    put = &dev_put_building(instance_id, home_id, &1, &2, &3, &4, &5)

    with {:ok, system} <- Game.call(instance_id, :stellar_system, home_id, :get_state),
         {:ok, body, infra_key, [idle_tile, damaged_tile | rest]} <- buildings_planet(system),
         {queued_tiles, free_tiles} = Enum.split(rest, length(@buildings_queued)),
         :ok <- buildings_in_content(instance_id, [{infra_key, @buildings_infra_level} | Enum.map(keys, &{&1, 1})]),
         {:ok, patents} <- fund_buildings(instance_id, profile_id, infra_key, keys),
         :ok <- put.(body.uid, 1, infra_key, @buildings_infra_level, :built),
         :ok <- put.(body.uid, idle_tile, @buildings_idle, 1, :built),
         :ok <- put.(body.uid, damaged_tile, @buildings_damaged, 1, :damaged),
         orders = Enum.zip(queued_tiles, @buildings_queued),
         :ok <- each_ok(orders, &order_building(instance_id, profile_id, home_id, body.uid, &1)),
         {:ok, system} <- Game.call(instance_id, :stellar_system, home_id, :get_state) do
      queue = Queue.to_list(system.queue.queue)
      Logger.info("[dev-fixture] buildings on #{body.name} (#{body.uid}): queue=#{length(queue)}")

      {:ok,
       %{
         body_uid: body.uid,
         body_name: body.name,
         infrastructure: %{tile: 1, key: infra_key, level: @buildings_infra_level},
         idle: %{tile: idle_tile, key: @buildings_idle, level: 1},
         damaged: %{tile: damaged_tile, key: @buildings_damaged, level: 1},
         queued: Enum.map(orders, fn {tile, key} -> %{tile: tile, key: key, level: 1} end),
         free_tiles: free_tiles,
         patents: patents,
         queue:
           Enum.map(queue, fn item ->
             %{id: item.id, type: item.type, key: item.prod_key, tile: item.tile_id, remaining: item.remaining_prod}
           end)
       }}
    end
  end

  # Home's inhabited planet: the habitable planet whose tile 1 holds a
  # finished infrastructure building. Needs four free tiles for the
  # placements and orders, plus one left free for the build menu.
  defp buildings_planet(system) do
    planet =
      Enum.find(system.bodies, fn body ->
        body.type == :habitable_planet and
          Enum.any?(body.tiles, &(&1.id == 1 and &1.building_status == :built))
      end)

    free =
      if planet do
        planet.tiles
        |> Enum.filter(&(&1.id > 1 and &1.building_status == :empty and &1.construction_status == :none))
        |> Enum.map(& &1.id)
        |> Enum.sort()
      end

    cond do
      is_nil(planet) -> {:error, {:buildings, :no_inhabited_habitable_planet}}
      length(free) < 3 + length(@buildings_queued) -> {:error, {:buildings, :not_enough_free_tiles, planet.uid, free}}
      true -> {:ok, planet, Enum.find(planet.tiles, &(&1.id == 1)).building_key, free}
    end
  end

  defp buildings_in_content(instance_id, key_levels) do
    Enum.find_value(key_levels, :ok, fn {key, level} ->
      case Data.Querier.one(Data.Game.Building, instance_id, key) do
        %{levels: levels} ->
          if Enum.any?(levels, &(&1.level == level)), do: nil, else: {:error, {:buildings, key, level}}

        _ ->
          {:error, {:buildings, :not_in_this_speed, key}}
      end
    end)
  end

  defp level_info(instance_id, key, level) do
    Data.Querier.one(Data.Game.Building, instance_id, key).levels |> Enum.find(&(&1.level == level))
  end

  # Grant the exact technology for the patents (same price formula as
  # Player.purchase_patent/2) and the exact credit for the orders, then
  # buy the patents: every level-1 patent of the cast plus the
  # infrastructure's level-2 patent, ancestors first. Returns the bought
  # keys.
  defp fund_buildings(instance_id, profile_id, infra_key, keys) do
    with {:ok, player} <- Game.call(instance_id, :player, profile_id, :get_state) do
      c = Data.Querier.one(Data.Game.Constant, instance_id, :main)
      mult = Instance.Mutators.cost_multiplier(instance_id, :patent)

      to_buy =
        [{infra_key, @buildings_infra_level} | Enum.map(keys, &{&1, 1})]
        |> Enum.map(fn {key, level} -> level_info(instance_id, key, level).patent end)
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(&ancestry(Data.Game.Patent, instance_id, &1))
        |> Enum.uniq()
        |> Enum.reject(&(&1 in player.patents))

      technology =
        to_buy
        |> Enum.with_index(length(player.patents))
        |> Enum.map(fn {key, n} ->
          Data.Querier.one(Data.Game.Patent, instance_id, key).cost * (1 + n * c.patent_level_price_increase) * mult
        end)
        |> Enum.sum()

      credit = @buildings_queued |> Enum.map(&level_info(instance_id, &1, 1).credit) |> Enum.sum()
      grant = %{credit: credit, technology: ceil(technology) + 1, ideology: 0}
      call = &Game.call(instance_id, :player, profile_id, &1)

      with :ok <- call.({:cheat, :grant_resources, grant}),
           :ok <- each_ok(to_buy, &call.({:purchase_patent, &1})) do
        {:ok, to_buy}
      else
        {:error, _} = error -> error
        other -> {:error, {:fund_buildings, other}}
      end
    end
  end

  # ---------------------------------------------------------------- schools

  # The `schools` sub-option's cast (docs/agent-training.md): a finished
  # Delta Polytech (one seat for any agent of the owner) and an Orb-INTEL
  # (a seat per level for Erased) on home's inhabited planet. Both are
  # open-biome buildings, so they fit the starter layout's habitable
  # planet at every speed. The Orb-INTEL is level 2 where the content has
  # one: Flash buildings have a single level.
  @schools [university_open: 1, counterintelligence_open: 2]

  defp maybe_place_schools(_instance_id, _home_id, false), do: {:ok, nil}

  defp maybe_place_schools(instance_id, home_id, true) do
    with {:ok, system} <- Game.call(instance_id, :stellar_system, home_id, :get_state),
         {:ok, body, tiles} <- schools_planet(system),
         schools = Enum.map(@schools, fn {key, level} -> {key, min(level, max_level(instance_id, key))} end),
         :ok <- buildings_in_content(instance_id, schools),
         placed = Enum.zip(tiles, schools),
         :ok <-
           each_ok(placed, fn {tile, {key, level}} ->
             dev_put_building(instance_id, home_id, body.uid, tile, key, level, :built)
           end) do
      {:ok,
       %{
         body_uid: body.uid,
         buildings: Enum.map(placed, fn {tile, {key, level}} -> %{tile: tile, key: key, level: level} end)
       }}
    end
  end

  # A university takes agents of `university_min_level` or more: the
  # player's agents are beginners, so each one on board is handed the
  # experience it is short of, through the cast a Training Center uses
  # (levels, skill points and stats follow as they would in play). Called
  # once the player's own hand is placed.
  defp maybe_season_agents(_instance_id, _profile_id, false), do: :ok

  defp maybe_season_agents(instance_id, profile_id, true) do
    level = Data.Querier.one(Data.Game.Constant, instance_id, :main).university_min_level
    # total experience at which an agent reaches `level` (Character.get_next_level_experience/1)
    needed = Float.round(10 * level + :math.pow(level / 2, 2.5))

    with {:ok, player} <- Game.call(instance_id, :player, profile_id, :get_state) do
      each_ok(player.characters, fn %{id: id} ->
        with {:ok, character} <- Game.call(instance_id, :character, id, :get_state) do
          if character.level < level,
            do: Game.cast(instance_id, :character, id, {:add_experience, needed - character.experience.value + 1})

          case Game.call(instance_id, :character, id, :get_state) do
            {:ok, %{level: reached}} when reached >= level -> :ok
            {:ok, %{level: reached}} -> {:schools, :agent_level, id, reached}
            other -> other
          end
        end
      end)
    end
  end

  defp max_level(instance_id, key) do
    case Data.Querier.one(Data.Game.Building, instance_id, key) do
      %{levels: [_ | _] = levels} -> levels |> Enum.map(& &1.level) |> Enum.max()
      _ -> 1
    end
  end

  # Home's inhabited planet, as buildings_planet/1 finds it, with a free
  # tile per school.
  defp schools_planet(system) do
    planet =
      Enum.find(system.bodies, fn body ->
        body.type == :habitable_planet and
          Enum.any?(body.tiles, &(&1.id == 1 and &1.building_status == :built))
      end)

    free =
      if planet do
        planet.tiles
        |> Enum.filter(&(&1.id > 1 and &1.building_status == :empty and &1.construction_status == :none))
        |> Enum.map(& &1.id)
        |> Enum.sort()
      end

    cond do
      is_nil(planet) -> {:error, {:schools, :no_inhabited_habitable_planet}}
      length(free) < length(@schools) -> {:error, {:schools, :not_enough_free_tiles, planet.uid, free}}
      true -> {:ok, planet, Enum.take(free, length(@schools))}
    end
  end

  defp dev_put_building(instance_id, system_id, body_uid, tile_id, key, level, status) do
    case Game.call(instance_id, :stellar_system, system_id, {:dev_put_building, body_uid, tile_id, key, level, status}) do
      {:ok, _system} -> :ok
      other -> {:error, {:dev_put_building, key, tile_id, other}}
    end
  end

  # The build menu's own call (Production.vue → PlayerChannel
  # "order_building"): the player agent replies with its new state, or
  # {:error, reason}.
  defp order_building(instance_id, profile_id, system_id, body_uid, {tile_id, key}) do
    case Game.call(instance_id, :player, profile_id, {:order_building, system_id, "build", {body_uid, tile_id, key, 1}}) do
      %{patents: _} -> :ok
      other -> {:error, {:order_building, key, tile_id, other}}
    end
  end

  defp each_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        other -> {:halt, {:error, {item, other}}}
      end
    end)
  end

  defp systems_by_distance(galaxy, home_id) do
    case Enum.find(galaxy.stellar_systems, &(&1.id == home_id)) do
      nil ->
        {:error, {:home_not_in_galaxy, home_id}}

      home ->
        {:ok,
         Enum.sort_by(galaxy.stellar_systems, fn s ->
           :math.pow(s.position.x - home.position.x, 2) + :math.pow(s.position.y - home.position.y, 2)
         end)}
    end
  end

  defp pick_system(systems, status, exclude, accept?) do
    systems
    |> Enum.filter(&(&1.status == status and &1.id not in exclude))
    |> Enum.find(accept?)
    |> case do
      nil -> {:error, {:no_system_found, status}}
      system -> {:ok, system.id}
    end
  end

  # the sector rule colonization and Control both check
  defp takeable?(instance_id, system_id, faction) do
    Game.call(instance_id, :galaxy, :master, {:check_system_takeability, system_id, faction}) == {:ok, :takeable}
  end

  # {:claim_system, _} / {:claim_dominion, _} are casts (the game fires
  # them from colonization and Control). A cast then a call from this
  # process reach the player agent in order, so the first get_state
  # normally shows the claim; the short retry is a safety net.
  defp claim_and_confirm(instance_id, profile_id, {_, system_id} = message, list_key) do
    Game.cast(instance_id, :player, profile_id, message)
    confirm_claim(instance_id, profile_id, system_id, list_key, message, 20)
  end

  defp confirm_claim(instance_id, profile_id, system_id, list_key, message, attempts) do
    case Game.call(instance_id, :player, profile_id, :get_state) do
      {:ok, player} ->
        cond do
          Enum.any?(Map.fetch!(player, list_key), &(&1.id == system_id)) ->
            {:ok, player}

          attempts > 1 ->
            Process.sleep(50)
            confirm_claim(instance_id, profile_id, system_id, list_key, message, attempts - 1)

          true ->
            {:error, {:claim_not_applied, message}}
        end

      other ->
        {:error, {:claim_not_applied, message, other}}
    end
  end

  defp maybe_destabilize(instance_id, system_id, true) do
    with {:ok, system} <- Game.call(instance_id, :stellar_system, system_id, :get_state) do
      penalty = max(system.happiness.value, 0) + @empire_destabilize_depth
      # the Destabilize action's own cast (EncourageHate.finish/2)
      Game.cast(instance_id, :stellar_system, system_id, {:add_happiness_penalty, :encourage_hate, penalty})

      case Game.call(instance_id, :stellar_system, system_id, :get_state) do
        {:ok, %{population_status: :normal}} -> {:error, {:destabilize_failed, :still_normal}}
        {:ok, %{population_status: status}} -> {:ok, status}
        other -> {:error, {:destabilize_failed, other}}
      end
    end
  end

  defp maybe_destabilize(instance_id, system_id, false) do
    with {:ok, system} <- Game.call(instance_id, :stellar_system, system_id, :get_state),
         do: {:ok, system.population_status}
  end

  # Make the account's beta-feature set exactly the requested list, so
  # repeated fixture runs are deterministic regardless of what a previous
  # test enabled. `nil` (param absent) leaves the account untouched.
  defp set_features(_account, nil), do: :ok

  defp set_features(account, features) when is_list(features) do
    Enum.each(RC.Accounts.AccountFeature.known(), fn key ->
      Accounts.set_feature(account.id, key, key in features)
    end)
  end

  defp set_features(_account, _features), do: :ok

  defp grant_resources(instance_id, profile_id, %{} = grant) do
    amounts = %{
      credit: sanitize_amount(grant["credit"]),
      technology: sanitize_amount(grant["technology"]),
      ideology: sanitize_amount(grant["ideology"])
    }

    if Enum.any?(Map.values(amounts), &(&1 > 0)) do
      Game.call(instance_id, :player, profile_id, {:cheat, :grant_resources, amounts})
    end

    :ok
  end

  defp grant_resources(_instance_id, _profile_id, _grant), do: :ok

  defp sanitize_amount(value) when is_number(value) and value > 0, do: min(value, 10_000_000)
  defp sanitize_amount(_), do: 0

  # Mint a real character and hand it to `owner` inside `system_id` through
  # the same player-agent call the seduction action uses — no shortcuts, so
  # the character is fully owned, supervised, and targetable.
  defp place(instance_id, owner_profile_id, type, rank, system_id) do
    {:ok, tmp_id} = Game.call(instance_id, :character_market, :master, :get_next_character_id)
    character = GameCharacter.new(tmp_id, type, rank, 1, instance_id)
    :ok = Game.call(instance_id, :player, owner_profile_id, {:convert_character, character, system_id})
  end

  defp armada_groups(layout, key) do
    layout
    |> Map.get(key, [])
    |> Enum.filter(&(is_integer(&1) and &1 >= 2 and &1 <= 3))
  end

  defp admiral_ids(instance_id, profile_id) do
    {:ok, player} = Game.call(instance_id, :player, profile_id, :get_state)

    player.characters
    |> Enum.filter(&(&1.type == :admiral))
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  # Group the caller's existing admirals (in id order) into armadas via
  # the real form/join player-agent calls.
  defp form_own_armadas(instance_id, profile_id, groups) do
    {armadas, _rest} =
      Enum.reduce(groups, {[], admiral_ids(instance_id, profile_id)}, fn size, {acc, remaining} ->
        {members, rest} = Enum.split(remaining, size)

        case members do
          [a, b | more] ->
            :ok = Game.call(instance_id, :player, profile_id, {:form_armada, a, b})
            Enum.each(more, fn c -> :ok = Game.call(instance_id, :player, profile_id, {:join_armada, c, a}) end)
            {[members | acc], rest}

          _ ->
            {acc, rest}
        end
      end)

    Enum.reverse(armadas)
  end

  # Mint `size` fresh navarchs for a puppet in the caller's starting
  # system and form them into an armada.
  defp place_armada(instance_id, profile_id, system_id, size) do
    before_ids = admiral_ids(instance_id, profile_id)

    for _ <- 1..size, do: place(instance_id, profile_id, :admiral, :common, system_id)

    [a, b | rest] = (admiral_ids(instance_id, profile_id) -- before_ids) |> Enum.sort()
    :ok = Game.call(instance_id, :player, profile_id, {:form_armada, a, b})
    Enum.each(rest, fn c -> :ok = Game.call(instance_id, :player, profile_id, {:join_armada, c, a}) end)

    [a, b | rest]
  end

  defp ensure_profile(account) do
    case RC.Repo.get_by(Profile, account_id: account.id) do
      nil ->
        {:ok, profile} =
          Accounts.create_profile(%{account_id: account.id, name: account.name, avatar: "todo"})

        profile

      profile ->
        profile
    end
  end

  defp ensure_puppet(email) do
    {:ok, account} = Accounts.get_account_by_email(email)
    ensure_profile(account)
  end
end
