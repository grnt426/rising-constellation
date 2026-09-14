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
  (`{:claim_dominion, _}`, as a successful Control does); and the home
  system gets a Destabilization penalty (`{:add_happiness_penalty,
  :encourage_hate, _}`, as Destabilize does) deep enough to leave the
  Normal population status. The response gains an `empire` block:

      %{home, owned2, dominion, autonomous, uninhabited, destabilized,
        population_status, systems, dominions, lexes, max_systems,
        max_dominions}

  `autonomous` and `uninhabited` are the nearest remaining systems of that
  status (not claimed). Without the option `empire` is `null`.

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
         {:ok, population_status} <- maybe_destabilize(instance_id, home_id, destabilize?),
         {:ok, player} <- Game.call(instance_id, :player, profile_id, :get_state) do
      Logger.info(
        "[dev-fixture] empire home=#{home_id} owned2=#{owned2_id} dominion=#{dominion_id} " <>
          "autonomous=#{autonomous_id} uninhabited=#{uninhabited_id} status=#{population_status}"
      )

      {:ok,
       %{
         home: home_id,
         owned2: owned2_id,
         dominion: dominion_id,
         autonomous: autonomous_id,
         uninhabited: uninhabited_id,
         destabilized: if(destabilize?, do: home_id),
         population_status: population_status,
         systems: Enum.map(player.stellar_systems, & &1.id),
         dominions: Enum.map(player.dominions, & &1.id),
         lexes: player.policies,
         max_systems: player.max_systems.value,
         max_dominions: player.max_dominions.value
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
        |> Enum.flat_map(&lex_ancestry(instance_id, &1))
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

  # [root, ..., key]; an unknown key is left for purchase_doctrine to refuse
  defp lex_ancestry(instance_id, key) do
    case Data.Querier.one(Data.Game.Doctrine, instance_id, key) do
      %{ancestor: parent} when not is_nil(parent) -> lex_ancestry(instance_id, parent) ++ [key]
      _ -> [key]
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
