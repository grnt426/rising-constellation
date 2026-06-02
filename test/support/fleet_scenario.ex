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
      on_strike: false
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
  end

  defmodule FakeCharacter do
    @moduledoc false
    use GenServer

    @impl true
    def init(character), do: {:ok, character}

    @impl true
    def handle_call(:get_state, _from, character), do: {:reply, {:ok, character}, character}

    # Test-only mutator: apply a user-supplied 1-arity fn to the
    # internal character struct. Lets scenarios flip action_status /
    # reaction mid-test to simulate the race where the system snapshot
    # and the character agent disagree.
    @impl true
    def handle_call({:update, fun}, _from, character) when is_function(fun, 1),
      do: {:reply, :ok, fun.(character)}
  end
end
