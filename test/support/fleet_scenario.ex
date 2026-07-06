defmodule Test.FleetScenario do
  @moduledoc """
  Lightweight harness for scripting fleet-interaction scenarios as
  ExUnit tests.

  ## What this is

  The production-side game agents (StellarSystem.Agent, Character.Agent,
  …) carry a lot of incidental state — tick scheduling, action queues,
  player broadcasts, snapshot persistence, the whole orchestrator — that
  is irrelevant when we only want to exercise the interception
  predicate. Booting all of that for each test makes scenarios slow,
  hard to control, and dependent on a synthesizable galaxy.

  Instead, this harness spawns *minimal* `GenServer` stand-ins that
  register themselves in `Game.Registry` under the same
  `{instance_id, type, agent_id}` name tuples the real agents use and
  reply to a handful of `:get_state`-style calls with fixtures the test
  controls. From the perspective of any caller doing
  `Game.call(instance_id, :stellar_system, id, :get_state)`, a fake is
  indistinguishable from the real thing — there's no monkey-patching.

  ## What you get

  Three setup helpers, plus pure builders for the underlying structs:

    * `spawn_fake_stellar_system/2` — `{system, pid}` registered as
      `{instance_id, :stellar_system, system_id}`.
    * `spawn_fake_character/2` — `{character, pid}` registered as
      `{instance_id, :character, character_id}`.
    * `unique_instance_id/0` — gives every test its own integer
      `instance_id` so the harness can run `async: true` without two
      tests stomping on the same registry slot.

  ## What this does NOT cover

  This is a *predicate* harness. It exercises
  `Instance.Character.Actions.Fight.find_hostiles/3` and any function
  whose only dependency on the live game is `Game.call(:get_state)`. It
  is deliberately scoped to NOT engage the full
  `check_interception → Fight.start → Fight.Manager` pipeline — that
  would require mocking the rand agent, the galaxy agent, the
  player agent, and the orchestrator, which is exactly the cost the
  refactor sidesteps.

  When a future scenario needs full engagement, the right next step is
  either (a) extend this harness with a fake rand/galaxy/player triplet
  and a public `engage_hostiles/3` Fight helper, or (b) graduate to a
  full instance-fixture test. Until then, the find_hostiles assertion
  is what gates regressions on the "who is selected as a hostile"
  contract — which is exactly the layer the original Bug 1 lives in.
  """

  alias Instance.Character.Action
  alias Instance.Character.ActionQueue
  alias Instance.Character.Character
  alias Instance.Character.Player, as: CharacterPlayer
  alias Instance.Galaxy.Galaxy
  alias Instance.Player.Player
  alias Instance.StellarSystem.Character, as: SystemCharacter
  alias Instance.StellarSystem.StellarSystem

  ## Public API

  @doc """
  Generate a per-test integer instance_id. Uses the BEAM's monotonic
  counter so two tests scheduled at the same wall-clock millisecond
  still get distinct ids.
  """
  def unique_instance_id, do: System.unique_integer([:positive])

  @doc """
  Spawn a fake `StellarSystem.Agent`-stand-in that replies to
  `:get_state` with the built `StellarSystem` struct.

  Required opts: `:instance_id`, `:system_id`.
  Optional opts (defaults in parentheses):

    * `:characters` (`[]`) — list of `StellarSystem.Character` structs
      to put in `system.characters`. Build them with
      `build_system_character/1`.
    * `:status` (`:inhabited_player`) — system status. Raid.start
      requires one of `:inhabited_player`/`:inhabited_dominion`/
      `:inhabited_neutral`, so the default is the most common one.
    * `:owner` (`nil`) — `StellarSystem.Player` struct or `nil`.
    * `:siege` (`nil`) — an `Instance.StellarSystem.Siege` or `nil`.
      `nil` is the "no siege ongoing" case that lets a raid start.
    * `:name` (`"sys-{system_id}"`) — for log/notif rendering.
  """
  def spawn_fake_stellar_system(_test_pid, opts) do
    instance_id = Keyword.fetch!(opts, :instance_id)
    system_id = Keyword.fetch!(opts, :system_id)
    characters = Keyword.get(opts, :characters, [])

    system = %{build_system(opts) | characters: characters}

    # Start the GenServer with a `name:` that points at Horde.Registry —
    # the GenServer registers itself on init, so we don't need a
    # separate `claim_registry_slot` round-trip. This is the same
    # name-tuple shape the real Core.TickServer-based agents use,
    # which is what makes the fake indistinguishable from production
    # to any caller doing Game.call/4.
    {:ok, pid} =
      GenServer.start_link(
        __MODULE__.FakeStellarSystem,
        system,
        name: Game.via_tuple({instance_id, :stellar_system, system_id})
      )

    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :shutdown) end)

    {system, pid}
  end

  @doc """
  Spawn a fake `Character.Agent`-stand-in that replies to `:get_state`
  with the built `Character.Character` struct.

  Required opts: `:instance_id`, `:character_id`, `:faction`,
  `:system`.

  Optional opts (defaults in parentheses):

    * `:reaction` (`:defend`) — `army.reaction`.
    * `:action_status` (`:idle`) — `character.action_status`.
    * `:has_ships?` (`true`) — when true, the army has one filled tile
      so `Army.has_ship?/1` is true (mirrors a normal admiral). When
      false, the army has only empty tiles.
    * `:type` (`:admiral`).
    * `:status` (`:on_board`).
    * `:owner_id` (`character_id + 1_000`).
    * `:owner_name` (`"player-{owner_id}"`).
    * `:faction_id` (`1`).
  """
  def spawn_fake_character(_test_pid, opts) do
    instance_id = Keyword.fetch!(opts, :instance_id)
    character_id = Keyword.fetch!(opts, :character_id)

    character = build_character(opts)

    {:ok, pid} =
      GenServer.start_link(
        __MODULE__.FakeCharacter,
        character,
        name: Game.via_tuple({instance_id, :character, character_id})
      )

    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :shutdown) end)

    {character, pid}
  end

  ## Struct builders (pure)

  @doc """
  Build a `StellarSystem.Character` summary — the slimmed-down struct
  that lives in `system.characters`. This is what
  `find_hostiles`' first filter sees before it issues the
  `:get_state` call against the character agent.
  """
  def build_system_character(opts) do
    character_id = Keyword.fetch!(opts, :character_id)
    faction = Keyword.fetch!(opts, :faction)
    owner_id = Keyword.get(opts, :owner_id, character_id + 1_000)
    owner_name = Keyword.get(opts, :owner_name, "player-#{owner_id}")
    faction_id = Keyword.get(opts, :faction_id, 1)
    type = Keyword.get(opts, :type, :admiral)

    %SystemCharacter{
      id: character_id,
      type: type,
      name: "char-#{character_id}",
      level: 1,
      owner: %CharacterPlayer{id: owner_id, name: owner_name, faction: faction, faction_id: faction_id},
      protection: 10,
      determination: 10,
      cover: nil
    }
  end

  @doc """
  Build a `Character.Character` struct (the full one — what
  `Game.call(:character, id, :get_state)` returns).
  """
  def build_character(opts) do
    character_id = Keyword.fetch!(opts, :character_id)
    instance_id = Keyword.fetch!(opts, :instance_id)
    faction = Keyword.fetch!(opts, :faction)
    system = Keyword.fetch!(opts, :system)
    reaction = Keyword.get(opts, :reaction, :defend)
    action_status = Keyword.get(opts, :action_status, :idle)
    has_ships? = Keyword.get(opts, :has_ships?, true)
    type = Keyword.get(opts, :type, :admiral)
    status = Keyword.get(opts, :status, :on_board)
    owner_id = Keyword.get(opts, :owner_id, character_id + 1_000)
    owner_name = Keyword.get(opts, :owner_name, "player-#{owner_id}")
    faction_id = Keyword.get(opts, :faction_id, 1)

    struct(Character, %{
      id: character_id,
      instance_id: instance_id,
      type: type,
      status: status,
      system: system,
      action_status: action_status,
      actions: ActionQueue.new(),
      owner: %CharacterPlayer{id: owner_id, name: owner_name, faction: faction, faction_id: faction_id},
      army: minimal_army(has_ships?: has_ships?, reaction: reaction),
      name: "char-#{character_id}",
      level: 1,
      protection: 10,
      determination: 10,
      on_strike: false,
      # Engagement-time fields. The predicate harness never exercises
      # these — they're added so Phase-1 scenarios that drive Fight.start
      # through Character.compute_bonus/1 don't crash:
      #
      #   * `experience` — Fight.Army.convert reads
      #     `character.experience.value`. Zero DynamicValue = "no XP."
      #
      #   * `skills` — Character.extract_bonus iterates over
      #     `Enum.with_index(state.skills)` and looks up a
      #     specialization at each index. :admiral has 6
      #     specializations (indices 0..5), so we pass 6 zero entries.
      #     All zeros means every per-skill bonus multiplies out to 0
      #     and never produces an actual stat change. Tests that want
      #     a real skill-driven bonus override this opt explicitly.
      #
      #   * `specialization` / `second_specialization` — used by the
      #     skill-allocation logic on level-up. Set to known admiral
      #     specs (matching the production seed data) so the lookups
      #     succeed.
      #
      #   * `bonuses` — Character.extract_bonus walks `state.bonuses`
      #     as a `%{from => [bonus_data]}` map. Empty map = "no
      #     external bonuses applied."
      experience: Keyword.get(opts, :experience, Core.DynamicValue.new(0.0)),
      skills: Keyword.get(opts, :skills, [0, 0, 0, 0, 0, 0]),
      specialization: Keyword.get(opts, :specialization, :strategist),
      second_specialization: Keyword.get(opts, :second_specialization, :butcher),
      bonuses: Keyword.get(opts, :bonuses, %{})
    })
  end

  @doc """
  Build the `Instance.Character.Action` that a queued raid (or jump,
  fight, …) would put into the action queue. Mirrors `Action.new/1`'s
  contract but lets the test override `:started_at` etc. for race
  scenarios.
  """
  def build_action(type, data, opts \\ []) do
    %Action{
      type: type,
      data: data,
      total_time: Keyword.get(opts, :total_time, 5),
      remaining_time: Keyword.get(opts, :remaining_time, 5),
      started_at: Keyword.get(opts, :started_at, nil),
      cumulated_pauses: Keyword.get(opts, :cumulated_pauses, nil)
    }
  end

  ## Phase 1: full-engagement harness
  ##
  ## The additions below let `Fight.start/2` (the engagement that
  ## happens *after* `find_hostiles/3` selects someone) run end-to-end
  ## against fake agents. The dependency surface — beyond the stellar
  ## system + character pair the predicate harness already covers — is:
  ##
  ##   * `:rand`     — `Fight.Manager` and the flee-roll inside
  ##     `check_interception` both ask the rand agent for dice values.
  ##   * `:galaxy`   — `Fight.start`'s notif-and-report stage calls
  ##     `:get_state` to check `is_tutorial?/1` (which gates the DB
  ##     write); the flee branch also calls `{:get_closest_system, …}`.
  ##   * `:player`   — every surviving combatant goes through
  ##     `{:fight_callback, status, character}` and the per-player
  ##     `{:push_notifs, notif}` broadcast.
  ##   * an instance-supervisor under `{instance_id, :instance_supervisor}`
  ##     so `Instance.Manager.kill_child/2` can run without crashing
  ##     when a death outcome occurs. We use a real `DynamicSupervisor`
  ##     even though the fake characters are not actually its children —
  ##     `terminate_child` returns `{:error, :not_found}` in that case,
  ##     which kill_child neither pattern-matches nor pipes through, so
  ##     the harmless error is dropped and the fake stays alive for
  ##     on_exit cleanup.
  ##
  ## Game data (read by `Data.Querier` inside `Fight.Manager.fight/2`
  ## and the flee roll) is loaded into `Horde.Registry`'s meta for the
  ## test instance via `load_game_data/2`.

  @doc """
  Register an empty `DynamicSupervisor` as
  `{instance_id, :instance_supervisor}` so
  `Instance.Manager.kill_child/2` can find it during a death-outcome
  scenario.
  """
  def spawn_instance_supervisor(_test_pid, opts) do
    instance_id = Keyword.fetch!(opts, :instance_id)

    {:ok, pid} =
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        name: Game.via_tuple({instance_id, :instance_supervisor})
      )

    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :shutdown) end)
    pid
  end

  @doc """
  Load the same `Data.Game.*` content the production instance loads,
  keyed against the test's `instance_id`. Required for any code path
  that calls `Data.Querier.one(Data.Game.Constant, …)` or
  `Data.Querier.all(Data.Game.Ship, …)` — that's `Fight.Manager.fight/2`
  and the constant lookup at the top of `check_interception/3`.

  Defaults to `[speed: :fast, mode: :dev]` so tests get short timeouts
  and dev-tuned constants. Tests can pass a different metadata to
  exercise prod or slow content.
  """
  def load_game_data(instance_id, metadata \\ [speed: :fast, mode: :dev]) do
    Data.Data.insert(instance_id, metadata)

    ExUnit.Callbacks.on_exit(fn ->
      try do
        Data.Data.clear(instance_id)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  @doc """
  Spawn a fake `:rand` agent under `{instance_id, :rand, :master}`.

  Two knobs:

    * `:uniform_value` (default `0.5`) — returned for every
      `{:uniform}` call, and used to compute `{:uniform, max}` as
      `trunc(uniform_value * max)`.
    * `:random_index` (default `0`) — index used for every
      `{:random, list}` call (mod list length).

  This gives every call a fully deterministic result. Pass different
  values to flip a flee roll, force a specific ship-targeting order,
  etc. without seeding `:rand`'s real PRNG.
  """
  def spawn_fake_rand(_test_pid, opts) do
    instance_id = Keyword.fetch!(opts, :instance_id)

    {:ok, pid} =
      GenServer.start_link(
        __MODULE__.FakeRand,
        Keyword.take(opts, [:uniform_value, :random_index]),
        name: Game.via_tuple({instance_id, :rand, :master})
      )

    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :shutdown) end)
    pid
  end

  @doc """
  Spawn a fake `:galaxy` agent under `{instance_id, :galaxy, :master}`.

  Opts:

    * `:tutorial_id` (default `1`) — set non-`nil` so
      `Instance.Galaxy.Galaxy.is_tutorial/1` returns true and
      `Fight.start` skips the `RC.PlayerReports.create` DB write.
      Tests that want to exercise the report write set this to `nil`.
    * `:closest_systems` (default `%{}`) — `system_id → closest_system_id`
      map used by `{:get_closest_system, …}`. Missing keys fall back
      to returning the queried system_id (i.e., a self-loop). Set
      enough entries for the flee scenarios you actually exercise.
    * `:edges` (default `%{}`) — `{from_id, to_id} → weight` map used
      by `{:check_jump, from, to}`. The fake synthesizes the
      production `%{s1, s2, weight}` response with stub positions so
      `Jump.pre_validate` can compute a travel_time. Missing keys
      yield `:invalid_jump` (same as production). Required for any
      scenario that ends up adding a fresh jump to a queue — flee
      branches in particular call `Jump.pre_validate` on the
      synthesized flee jump.
  """
  def spawn_fake_galaxy(_test_pid, opts) do
    instance_id = Keyword.fetch!(opts, :instance_id)

    galaxy =
      struct(Galaxy, %{
        size: 10,
        stellar_systems: [],
        edges: [],
        sectors: [],
        blackholes: [],
        players: %{},
        tutorial_id: Keyword.get(opts, :tutorial_id, 1)
      })

    closest = Keyword.get(opts, :closest_systems, %{})
    edges = Keyword.get(opts, :edges, %{})

    {:ok, pid} =
      GenServer.start_link(
        __MODULE__.FakeGalaxy,
        %{galaxy: galaxy, closest: closest, edges: edges},
        name: Game.via_tuple({instance_id, :galaxy, :master})
      )

    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :shutdown) end)
    {galaxy, pid}
  end

  @doc """
  Spawn a fake `:player` agent under
  `{instance_id, :player, player_id}`.

  Responds to:

    * `:get_state` — returns `{:ok, player}` with a minimal `Player`
      struct (faction + name + id are filled; the rest is `nil` so the
      production callers that read other fields crash loudly rather
      than silently misbehave on a stub value).
    * `{:fight_callback, status, character}` — returns
      `{character, has_to_die?}` matching the production contract:
      `:victorious` and `:fleeing` keep the character alive,
      `:dead` flags `has_to_die? = true`. The call is *also* recorded
      so tests can assert it ran (`get_fight_callbacks/1`).
    * `{:push_notifs, notif}` (cast) — appends to an internal log
      that tests can pull via `get_notifs/1`.

  Use `get_fight_callbacks/1` and `get_notifs/1` for assertions; the
  fake doesn't try to replay the real `Player.fight_callback`'s
  side effects (`update_state` cast, flee jump, etc.) — those belong
  to the player-process contract and are out of scope here.
  """
  def spawn_fake_player(_test_pid, opts) do
    instance_id = Keyword.fetch!(opts, :instance_id)
    player_id = Keyword.fetch!(opts, :player_id)
    faction = Keyword.fetch!(opts, :faction)

    player =
      struct(Player, %{
        id: player_id,
        account_id: player_id + 10_000,
        faction_id: Keyword.get(opts, :faction_id, 1),
        faction: faction,
        name: Keyword.get(opts, :name, "player-#{player_id}"),
        is_dead: false,
        is_active: true,
        avatar: "",
        registration_id: player_id + 20_000
      })

    {:ok, pid} =
      GenServer.start_link(
        __MODULE__.FakePlayer,
        player,
        name: Game.via_tuple({instance_id, :player, player_id})
      )

    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :shutdown) end)
    {player, pid}
  end

  @doc """
  Pull the ordered list of `{status, character}` pairs the fake player
  observed across all `:fight_callback` invocations.
  """
  def get_fight_callbacks(player_pid) do
    GenServer.call(player_pid, :get_fight_callbacks)
  end

  @doc """
  Pull the ordered list of notifs the fake player received via
  `{:push_notifs, notif}` casts.
  """
  def get_notifs(player_pid) do
    GenServer.call(player_pid, :get_notifs)
  end

  @doc """
  Pull the ordered list of `{:update_system | :update_dominion, system}`
  casts the fake player received — the owner-notification channel that
  keeps `Player.StellarSystem` snapshots (side-panel agent dots,
  governor display) in sync with the live system.
  """
  def get_system_updates(player_pid) do
    GenServer.call(player_pid, :get_system_updates)
  end

  ## Internal helpers

  defp build_system(opts) do
    system_id = Keyword.fetch!(opts, :system_id)

    # Use struct/2 (which bypasses @enforce_keys) and only fill the
    # fields that find_hostiles + the surrounding interception/raid
    # callers actually read: id, name, status, owner, characters,
    # siege, instance_id. Other StellarSystem fields are left as nil —
    # if a future code path reads one of them through this harness,
    # the test will crash with a clear NilField error and we extend
    # this builder rather than smuggling in fake metric values.
    struct(StellarSystem, %{
      id: system_id,
      name: Keyword.get(opts, :name, "sys-#{system_id}"),
      status: Keyword.get(opts, :status, :inhabited_player),
      owner: Keyword.get(opts, :owner, nil),
      characters: [],
      siege: Keyword.get(opts, :siege, nil),
      instance_id: Keyword.get(opts, :instance_id)
    })
  end

  defp minimal_army(opts) do
    reaction = Keyword.fetch!(opts, :reaction)
    has_ships? = Keyword.fetch!(opts, :has_ships?)

    tiles =
      if has_ships? do
        # One filled tile is enough for Army.has_ship?/1 to return true,
        # mirroring an admiral that's combat-capable. We don't populate
        # the actual ship struct because find_hostiles never reaches
        # past has_ship? — the engagement path that DOES is exercised
        # by full integration tests (see scenario_fixture).
        [
          struct(Instance.Character.Tile, %{id: 1, ship_status: :filled, ship: nil}),
          struct(Instance.Character.Tile, %{id: 2, ship_status: :empty, ship: nil})
        ]
      else
        # An admiral with no ships — the user's "fleet has been
        # destroyed but the admiral is still on the system" edge case.
        [struct(Instance.Character.Tile, %{id: 1, ship_status: :empty, ship: nil})]
      end

    %Instance.Character.Army{
      tiles: tiles,
      reaction: reaction,
      maintenance: Core.Value.new(),
      repair_coef: Core.Value.new(),
      invasion_coef: Core.Value.new(),
      raid_coef: Core.Value.new()
    }
  end

  ## Fake agents

  defmodule FakeStellarSystem do
    @moduledoc false
    use GenServer

    @impl true
    def init(system), do: {:ok, system}

    @impl true
    def handle_call(:get_state, _from, system), do: {:reply, {:ok, system}, system}

    # Test-only setter: replace the `characters` list on this fake
    # stellar_system. Useful for "what if a character left between
    # push_character and check_interception" race-scenarios.
    @impl true
    def handle_call({:update_characters, characters}, _from, system),
      do: {:reply, :ok, %{system | characters: characters}}

    # Engagement-time: Fight.start's kill_character path removes the
    # losing admiral from the system before terminating the process.
    @impl true
    def handle_call({:remove_character, character, :on_board}, _from, system) do
      characters = Enum.reject(system.characters, fn c -> c.id == character.id end)
      system = %{system | characters: characters}
      {:reply, {:ok, system}, system}
    end

    # Engagement-time: Fight.check_interception's flee branch fires a
    # cast to cancel any ships the fleeing admiral had on order. The
    # fake just acks — the production code only uses the cast for the
    # side effect of mutating stellar_system state we don't model.
    @impl true
    def handle_cast({:cancel_ordered_ships, _character_id}, system),
      do: {:noreply, system}
  end

  defmodule FakeCharacter do
    @moduledoc false
    use GenServer

    @impl true
    def init(character), do: {:ok, character}

    @impl true
    def handle_call(:get_state, _from, character), do: {:reply, {:ok, character}, character}

    # Engagement-time: Instance.Manager.kill_child/2 calls :prepare_kill
    # on the process before DynamicSupervisor.terminate_child/2. The
    # real TickServer flips an internal kill flag to suppress
    # handoff-state save; we just ack.
    @impl true
    def handle_call(:prepare_kill, _from, character),
      do: {:reply, :ok, character}

    # Test-only mutator: apply a user-supplied 1-arity fn to the
    # internal character struct. Lets scenarios flip action_status /
    # reaction mid-test to simulate the race where the system snapshot
    # and the character agent disagree.
    @impl true
    def handle_call({:update, fun}, _from, character) when is_function(fun, 1),
      do: {:reply, :ok, fun.(character)}
  end

  defmodule FakeRand do
    @moduledoc false
    use GenServer

    @impl true
    def init(opts) do
      {:ok,
       %{
         uniform_value: Keyword.get(opts, :uniform_value, 0.5),
         random_index: Keyword.get(opts, :random_index, 0)
       }}
    end

    @impl true
    def handle_call({:uniform}, _from, state), do: {:reply, state.uniform_value, state}

    @impl true
    def handle_call({:uniform, max}, _from, state),
      do: {:reply, trunc(state.uniform_value * max), state}

    @impl true
    def handle_call({:random, list}, _from, state) when is_list(list) do
      element =
        case list do
          [] -> nil
          _ -> Enum.at(list, rem(state.random_index, length(list)))
        end

      {:reply, element, state}
    end

    # Optional override hook so a multi-step scenario can flip its
    # configured returns mid-test (e.g., one roll fails the flee
    # check, the next succeeds).
    @impl true
    def handle_call({:set, key, value}, _from, state),
      do: {:reply, :ok, Map.put(state, key, value)}
  end

  defmodule FakeGalaxy do
    @moduledoc false
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:get_state, _from, state), do: {:reply, {:ok, state.galaxy}, state}

    # Used by Fight.check_interception's flee branch. Falls back to a
    # self-loop when the test didn't configure a closest neighbor —
    # the production code consumes the result as the target of a flee
    # jump, so a self-loop tends to surface "you forgot to configure
    # this" as a Jump.pre_validate `same_position` throw, which is
    # noisier than a silent `nil` would be.
    @impl true
    def handle_call({:get_closest_system, system_id}, _from, state) do
      {:reply, Map.get(state.closest, system_id, system_id), state}
    end

    # Used by Jump.pre_validate when a flee branch (or any scenario
    # that queues a fresh jump) needs the distance between two
    # systems. We synthesize stub positions for s1/s2 so the
    # downstream code paths (Spatial bbox math etc.) have something to
    # compute against. Missing edges yield :invalid_jump exactly like
    # production.
    @impl true
    def handle_call({:check_jump, from_id, to_id}, _from, state) do
      reply =
        case Map.get(state.edges, {from_id, to_id}) do
          nil ->
            :invalid_jump

          weight ->
            %{
              s1: %{id: from_id, position: %Spatial.Position{x: from_id * 1.0, y: 0.0}},
              s2: %{id: to_id, position: %Spatial.Position{x: to_id * 1.0, y: 0.0}},
              weight: weight
            }
        end

      {:reply, reply, state}
    end
  end

  defmodule FakePlayer do
    @moduledoc false
    use GenServer

    @impl true
    def init(player), do: {:ok, %{player: player, fight_callbacks: [], notifs: [], system_updates: []}}

    @impl true
    def handle_call(:get_state, _from, state), do: {:reply, {:ok, state.player}, state}

    @impl true
    def handle_call({:fight_callback, status, character}, _from, state) do
      state = %{state | fight_callbacks: [{status, character} | state.fight_callbacks]}
      has_to_die? = status == :dead
      {:reply, {character, has_to_die?}, state}
    end

    @impl true
    def handle_call(:get_fight_callbacks, _from, state),
      do: {:reply, Enum.reverse(state.fight_callbacks), state}

    @impl true
    def handle_call(:get_notifs, _from, state),
      do: {:reply, Enum.reverse(state.notifs), state}

    @impl true
    def handle_call(:get_system_updates, _from, state),
      do: {:reply, Enum.reverse(state.system_updates), state}

    @impl true
    def handle_cast({:push_notifs, notif}, state) do
      additions = List.wrap(notif)
      {:noreply, %{state | notifs: Enum.reverse(additions) ++ state.notifs}}
    end

    @impl true
    def handle_cast({kind, system}, state) when kind in [:update_system, :update_dominion] do
      {:noreply, %{state | system_updates: [{kind, system} | state.system_updates]}}
    end
  end
end
