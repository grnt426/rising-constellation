defmodule Portal.Controllers.CheatChannel do
  @moduledoc """
  Out-of-band channel that short-circuits normal game economics.

  Three authorized caller classes, each re-asserted by every handler so a
  config slip can't accidentally expose cheats to real players:

    * stress-test bots (`account.is_bot`) — the original consumer, allowed
      on any instance (but only for the member-level ops below on
      non-cheat instances: the panel ops all require the instance flag);
    * any player of an instance created with cheat access
      (`Instance.Cheats.enabled?/1`) — member-level ops: giving (strictly
      positive) resources, clearing lex cooldowns, the fleet editor
      (instantly setting the ships of any deployed Navarch), and handing
      one of their own deployed agents to another player;
    * the game creator (`instances.account_id`) — additionally the
      game-shaping ops: runtime speed, instant settle, and the election
      fast-forward/reopen cheats.

  This powers the in-game Cheats tab used to test faction governments,
  game modes, fleet interactions, and "game DM" scenarios. Cheat-enabled
  games announce themselves in every faction's chat at genesis.

  Topic format: `cheat:player:{instance_id}:{player_id}`. Caller must
  already be authorised to act AS that player — same registration check the
  normal PlayerChannel does.
  """

  use Phoenix.Channel
  use Portal.ReplayRecorder

  require Logger

  # Runtime speed multipliers the set_speed cheat accepts (× the instance's
  # base speed factor). Whitelisted so a typo can't retime an instance to
  # something absurd.
  @allowed_speed_multipliers [0.25, 0.5, 1, 2, 5, 10, 20, 50]

  @resources ["credit", "technology", "ideology"]

  # Hard cap per grant — enough for any test scenario, small enough that a
  # slipped extra zero doesn't overflow client-side number formatting.
  @max_grant 1_000_000_000

  # Highest ship level the fleet editor places — 0-indexed like ship.level;
  # the panel's level input shows 1–16 (SimulatorShipPicker maxLevel).
  @max_ship_level 15

  def join("cheat:player:" <> channel_data, _params, socket) do
    [instance_id, player_id] =
      channel_data
      |> String.split(":")
      |> Enum.map(&String.to_integer/1)

    cond do
      not Instance.Manager.created?(instance_id) ->
        {:error, %{reason: "instance_not_instantiated"}}

      not cheat_access?(socket, instance_id) ->
        {:error, %{reason: "cheat_access_denied"}}

      not own_player?(socket, instance_id, player_id) ->
        {:error, %{reason: "not_authorised_for_player"}}

      true ->
        socket =
          socket
          |> assign(:instance_id, instance_id)
          |> assign(:player_id, player_id)
          |> assign(:channel_name, "cheat")
          # `has_replay` gates Portal.ReplayRecorder's per-action replay
          # persistence. Cheats are out-of-band stress-test/debug glue; we
          # don't want them mixed into game replays. Bot monitoring still
          # fires — it has its own gate (account.is_bot).
          |> assign(:has_replay, false)

        {:ok, socket}
    end
  end

  # Original bot cheat: grant resources to the topic's own player.
  # Amounts are validated non-negative — the channel never debits anyone,
  # no matter who is calling.
  record("grant_resources", payload, socket) do
    amounts = %{
      credit: Map.get(payload, "credit", 0),
      technology: Map.get(payload, "technology", 0),
      ideology: Map.get(payload, "ideology", 0)
    }

    with :ok <- assert_member_access(socket),
         true <-
           Enum.all?(Map.values(amounts), &(is_number(&1) and &1 >= 0 and &1 <= @max_grant)) or
             {:error, "invalid_amount"} do
      case Game.call(iid(socket), :player, pid(socket), {:cheat, :grant_resources, amounts}) do
        {:error, reason} -> {:error, %{reason: reason}}
        _ -> :ok
      end
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # Cheats tab: give one resource to one player, or to every player in the
  # instance ("target": "all").
  record("give_resources", %{"target" => target, "resource" => resource, "amount" => amount}, socket) do
    with :ok <- assert_member_access(socket),
         :ok <- assert_cheats_enabled(socket),
         true <- resource in @resources or {:error, "unknown_resource"},
         true <- (is_number(amount) and amount > 0 and amount <= @max_grant) or {:error, "invalid_amount"},
         {:ok, player_ids} <- resolve_targets(socket, target) do
      {credit, technology, ideology} =
        case resource do
          "credit" -> {amount, 0, 0}
          "technology" -> {0, amount, 0}
          "ideology" -> {0, 0, amount}
        end

      results =
        Enum.map(player_ids, fn player_id ->
          Game.call(iid(socket), :player, player_id, {:add_resources, credit, technology, ideology})
        end)

      granted = Enum.count(results, &(&1 == :ok))
      {:ok, %{granted: granted, targets: length(player_ids)}}
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # Cheats tab: instantly settle a system for the target player. Refused
  # when a player already owns the system — a forced transfer would run the
  # loser through {:lose_system, _}, and losing a last system kills that
  # player. Settling is for neutral/uninhabited/uninhabitable systems.
  record("settle_system", %{"target" => target, "system_id" => system_id}, socket) do
    with :ok <- assert_creator_access(socket),
         :ok <- assert_cheats_enabled(socket),
         true <- (is_integer(target) and is_integer(system_id)) or {:error, "invalid_payload"},
         {:ok, player_ids} <- resolve_targets(socket, "all"),
         true <- target in player_ids or {:error, "unknown_player"},
         {:ok, system} <- Game.call(iid(socket), :stellar_system, system_id, :get_state),
         true <- is_nil(system.owner) or {:error, "system_already_owned"} do
      case Game.call(iid(socket), :player, target, {:cheat_claim_system, system_id}) do
        :ok -> {:ok, %{settled: system_id, player: target}}
        {:error, reason} -> {:error, %{reason: reason}}
      end
    else
      {:error, reason} -> {:error, %{reason: reason}}
      :process_not_found -> {:error, %{reason: "system_not_found"}}
    end
  end

  # Cheats tab: end the pre-election founding grace period, every faction.
  record("skip_election_timer", %{}, socket) do
    gov_cheat_fanout(socket, :cheat_gov_skip_founding)
  end

  # Cheats tab: conclude every currently-open election round, every faction.
  record("conclude_elections", %{}, socket) do
    gov_cheat_fanout(socket, :cheat_gov_conclude_elections)
  end

  # Cheats tab: (re-)open the standard election slate, every faction —
  # vacant seats after a failed race, or a snap re-election mid-mandate.
  record("reopen_elections", %{}, socket) do
    gov_cheat_fanout(socket, :cheat_gov_reopen_elections)
  end

  # Cheats tab: clear lex-locking cooldowns for everyone — the per-faction
  # law-change cooldown and every player's policy re-lock cooldown.
  record("clear_lex_cooldowns", %{}, socket) do
    with :ok <- assert_member_access(socket),
         :ok <- assert_cheats_enabled(socket),
         {:ok, player_ids} <- resolve_targets(socket, "all") do
      faction_results =
        Enum.map(faction_ids(socket), fn faction_id ->
          Game.call(iid(socket), :faction, faction_id, :cheat_gov_clear_law_cooldown)
        end)

      player_results =
        Enum.map(player_ids, fn player_id ->
          Game.call(iid(socket), :player, player_id, :cheat_clear_policies_cooldown)
        end)

      {:ok,
       %{
         factions_cleared: Enum.count(faction_results, &(&1 == :ok)),
         players_cleared: Enum.count(player_results, &(&1 == :ok))
       }}
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # Cheats tab: retime the running instance (multiplier × base speed).
  record("set_speed", %{"multiplier" => multiplier}, socket) do
    with :ok <- assert_creator_access(socket),
         :ok <- assert_cheats_enabled(socket),
         true <- multiplier in @allowed_speed_multipliers or {:error, "invalid_multiplier"} do
      case Instance.Manager.call(iid(socket), {:cheat_set_speedup, multiplier}) do
        {:ok, :speedup_set, _count} -> {:ok, %{speedup: multiplier}}
        {:error, reason} -> {:error, %{reason: reason}}
      end
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # Cheats tab fleet editor: read or instantly rewrite the army of any
  # deployed Navarch — the caller's own or another player's (the panel
  # targets the Navarch last selected or opened). Member level, like
  # give_resources: it exists to stage fleet-interaction tests. Every reply
  # carries the Navarch's full, unobfuscated army (fleet_payload/1).
  record("fleet_get", payload, socket) do
    character_id = payload["character_id"]

    with :ok <- assert_member_access(socket),
         :ok <- assert_cheats_enabled(socket),
         true <- is_integer(character_id) or {:error, "invalid_payload"} do
      case Game.call(iid(socket), :character, character_id, :get_state) do
        {:ok, %{type: :admiral, status: :on_board} = character} -> {:ok, fleet_payload(character)}
        {:ok, _character} -> {:error, %{reason: "not_a_deployed_admiral"}}
        _ -> {:error, %{reason: "character_not_found"}}
      end
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # A picked ship goes to the first empty tile; "shift" widens it to that
  # tile's whole line (empty tiles only), "shift" + "ctrl" overwrites the
  # line's built ships too — the battle simulator's shortcuts.
  record("fleet_add_ship", payload, socket) do
    mode =
      cond do
        payload["shift"] == true and payload["ctrl"] == true -> :override_line
        payload["shift"] == true -> :fill_line
        true -> :single
      end

    with {:ok, ship_key} <- parse_ship_key(payload["ship_key"]),
         {:ok, level} <- parse_ship_level(payload["level"]) do
      fleet_edit(socket, payload["character_id"], {:add, ship_key, level, mode})
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # Replace one tile's ship (the stack-size arrows send the next variant).
  record("fleet_set_ship", payload, socket) do
    with {:ok, tile_id} <- parse_tile_id(payload["tile_id"]),
         {:ok, ship_key} <- parse_ship_key(payload["ship_key"]),
         {:ok, level} <- parse_ship_level(payload["level"]) do
      fleet_edit(socket, payload["character_id"], {:set, tile_id, ship_key, level})
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  record("fleet_remove_ship", payload, socket) do
    case parse_tile_id(payload["tile_id"]) do
      {:ok, tile_id} -> fleet_edit(socket, payload["character_id"], {:remove, tile_id})
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # Remove every built ship (ships still in a shipyard queue stay).
  record("fleet_clear", payload, socket) do
    fleet_edit(socket, payload["character_id"], :clear)
  end

  # Cheats tab: hand one of the caller's own deployed agents to another
  # player, of any faction, ignoring the recipient's agent caps. Member
  # level — only the caller's own agents move. The guards (idle, on board,
  # no armada, …) and the snapshot-safe sequencing live in
  # Instance.Manager {:cheat_transfer_character, ...}.
  record("transfer_agent", payload, socket) do
    character_id = payload["character_id"]
    target = payload["target"]

    with :ok <- assert_member_access(socket),
         :ok <- assert_cheats_enabled(socket),
         true <- (is_integer(character_id) and is_integer(target)) or {:error, "invalid_payload"},
         {:ok, _player_ids} <- resolve_targets(socket, target) do
      case Instance.Manager.call(iid(socket), {:cheat_transfer_character, character_id, pid(socket), target}) do
        :ok -> {:ok, %{character: character_id, player: target}}
        {:error, reason} -> {:error, %{reason: reason}}
      end
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # Cheats tab: game-wide toggle letting every player recall an idle
  # on-board agent from any system — the way out of an over-cap roster when
  # none of the extra agents stands at home. Member level, like the
  # transfer that causes it.
  record("set_recall_anywhere", payload, socket) do
    enabled = payload["enabled"]

    with :ok <- assert_member_access(socket),
         :ok <- assert_cheats_enabled(socket),
         true <- is_boolean(enabled) or {:error, "invalid_payload"} do
      case Instance.Manager.call(iid(socket), {:cheat_set_recall_anywhere, enabled}) do
        {:ok, enabled} -> {:ok, %{recall_anywhere: enabled}}
        {:error, reason} -> {:error, %{reason: reason}}
      end
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # ---- authorization ---------------------------------------------------

  # Member level: stress-test bots (any instance — grant_resources compat)
  # or any player of a cheats-enabled instance. Join already proved the
  # caller owns the topic's player (own_player?/3), so the flag is all
  # that's left to check.
  defp cheat_access?(socket, instance_id) do
    is_bot?(socket) or Instance.Cheats.enabled?(instance_id)
  end

  defp assert_member_access(socket) do
    if cheat_access?(socket, iid(socket)), do: :ok, else: {:error, "cheat_access_denied"}
  end

  # Creator level: the game-shaping ops (runtime speed, instant settle,
  # election fast-forwards) stay restricted to the instance creator —
  # every player shares one clock and one map, so only the "game DM" gets
  # to rewrite them. Bots keep full access for stress scenarios.
  defp assert_creator_access(socket) do
    creator =
      is_bot?(socket) or
        (Instance.Cheats.enabled?(iid(socket)) and
           RC.Instances.own_instance?(socket.assigns.account.id, iid(socket)))

    if creator, do: :ok, else: {:error, "cheat_creator_only"}
  end

  # The panel ops (unlike the bot-oriented grant_resources) must never run
  # on a non-cheat instance, even for bots.
  defp assert_cheats_enabled(socket) do
    if Instance.Cheats.enabled?(iid(socket)), do: :ok, else: {:error, "cheats_disabled"}
  end

  defp is_bot?(socket) do
    case socket.assigns do
      %{account: %{is_bot: true}} -> true
      _ -> false
    end
  end

  defp own_player?(socket, instance_id, player_id) do
    RC.Registrations.account_owns_player?(socket.assigns.account.id, instance_id, player_id)
  end

  # ---- helpers ---------------------------------------------------------

  # Election-timer manipulation is creator-only — see assert_creator_access.
  defp gov_cheat_fanout(socket, op) do
    with :ok <- assert_creator_access(socket),
         :ok <- assert_cheats_enabled(socket) do
      results = Enum.map(faction_ids(socket), fn faction_id -> Game.call(iid(socket), :faction, faction_id, op) end)
      applied = Enum.count(results, &(&1 == :ok))

      # :ok on at least one faction is success; per-faction "nothing to do"
      # errors (:not_in_founding, :no_open_elections, :government_disabled)
      # only surface when NO faction applied, as a single aggregate reason.
      if applied > 0 do
        {:ok, %{factions_applied: applied}}
      else
        reason =
          results
          |> Enum.find_value(fn
            {:error, reason} -> reason
            _ -> nil
          end)
          |> Kernel.||("no_faction_applied")

        {:error, %{reason: reason}}
      end
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # Fleet editor: one army edit through the Navarch's own agent, which
  # validates it (deployed admiral, planned tiles untouched), re-checks the
  # instance flag and refreshes the owner's cached copy.
  defp fleet_edit(socket, character_id, edit) do
    with :ok <- assert_member_access(socket),
         :ok <- assert_cheats_enabled(socket),
         true <- is_integer(character_id) or {:error, "invalid_payload"} do
      case Game.call(iid(socket), :character, character_id, {:cheat_edit_army, edit}) do
        {:ok, character} -> {:ok, fleet_payload(character)}
        {:error, reason} -> {:error, %{reason: reason}}
        _ -> {:error, %{reason: "character_not_found"}}
      end
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  defp fleet_payload(character) do
    %{
      character: %{
        id: character.id,
        name: character.name,
        owner: %{id: character.owner.id, name: character.owner.name, faction: character.owner.faction}
      },
      tiles:
        Enum.map(character.army.tiles, fn tile ->
          ship = if is_map(tile.ship), do: tile.ship

          %{
            id: tile.id,
            status: tile.ship_status,
            ship_key: ship && ship.key,
            level: ship && ship.level
          }
        end)
    }
  end

  defp parse_ship_key(key) when is_binary(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> {:error, "unknown_ship"}
  end

  defp parse_ship_key(_key), do: {:error, "unknown_ship"}

  defp parse_ship_level(level) when is_integer(level) and level >= 0 and level <= @max_ship_level,
    do: {:ok, level}

  defp parse_ship_level(_level), do: {:error, "invalid_level"}

  defp parse_tile_id(tile_id) when is_integer(tile_id), do: {:ok, tile_id}
  defp parse_tile_id(_tile_id), do: {:error, "invalid_payload"}

  defp resolve_targets(socket, "all") do
    case Game.call(iid(socket), :galaxy, :master, :get_state) do
      {:ok, galaxy} -> {:ok, Map.keys(galaxy.players)}
      _ -> {:error, "instance_unavailable"}
    end
  end

  defp resolve_targets(socket, player_id) when is_integer(player_id) do
    case Game.call(iid(socket), :galaxy, :master, :get_state) do
      {:ok, galaxy} ->
        if Map.has_key?(galaxy.players, player_id),
          do: {:ok, [player_id]},
          else: {:error, "unknown_player"}

      _ ->
        {:error, "instance_unavailable"}
    end
  end

  defp resolve_targets(_socket, _target), do: {:error, "invalid_target"}

  defp faction_ids(socket) do
    case RC.Instances.get_instance(iid(socket)) do
      %{factions: factions} when is_list(factions) -> Enum.map(factions, & &1.id)
      _ -> []
    end
  end

  defp iid(socket), do: socket.assigns.instance_id
  defp pid(socket), do: socket.assigns.player_id
end
