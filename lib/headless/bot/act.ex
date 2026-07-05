defmodule Headless.Bot.Act do
  @moduledoc """
  The single place that knows engine payload shapes. Policies emit abstract
  action tuples; `execute/3` translates them into `Game.call` invocations
  against the player agent (payload shapes verified against
  lib/game/instance/player/agent.ex and the PlayerChannel handlers).

  Anything that isn't `{:error, reason}` counts as accepted — the engine is
  the validator. NOTE: `add_character_actions` pre-validation silently drops
  invalid entries (see Character.add_actions), so acceptance there only means
  "delivered"; policies must confirm via the character's action queue.
  """

  @type action ::
          {:purchase_patent, atom()}
          | {:purchase_doctrine, atom()}
          | {:purchase_policy_slot}
          | {:update_policies, [atom()]}
          | {:order_building, integer(), integer(), integer(), atom()}
          | {:order_ship, integer(), integer(), integer(), atom()}
          | {:hire_character, integer()}
          | {:activate_character, integer(), atom(), integer()}
          | {:queue_mission, integer(), [{integer(), integer()}], integer()}

  def execute(instance_id, player_id, action) do
    call(instance_id, player_id, translate(action))
  end

  defp translate({:purchase_patent, key}), do: {:purchase_patent, key}
  defp translate({:purchase_doctrine, key}), do: {:purchase_doctrine, key}
  defp translate({:purchase_policy_slot}), do: :purchase_policy_slot
  defp translate({:update_policies, keys}), do: {:update_policies, keys}

  defp translate({:order_building, system_id, body_id, tile_id, key}),
    do: {:order_building, system_id, "build", {body_id, tile_id, key, 1}}

  defp translate({:order_ship, system_id, character_id, tile_id, ship_key}),
    do: {:order_ship, system_id, {character_id, tile_id, ship_key, 1}}

  defp translate({:hire_character, id}), do: {:hire_character, id}
  defp translate({:update_reaction, id, reaction}), do: {:update_reaction, id, reaction}
  defp translate({:to_dominion, system_id}), do: {:transform_system_to_dominion, system_id}
  defp translate({:to_system, system_id}), do: {:transform_dominion_to_system, system_id}

  defp translate({:activate_character, id, mode, system_id}),
    do: {:activate_character, id, mode, system_id}

  # Payload shape from the engine's own usage (Character.flee,
  # lib/game/instance/character/character.ex:359) and the channel handler.
  # Jumps are star-lane constrained (Galaxy.check_jump → :invalid_jump when
  # no edge exists), so a mission is a CHAIN of per-edge hops + the final
  # colonization; hops come from the policy's BFS over galaxy.edges.
  defp translate({:queue_mission, character_id, hops, target_id}) do
    translate({:queue_travel_action, character_id, hops, "colonization", target_id})
  end

  # Generic travel-then-act mission: lane hops then a single targeted action
  # ("colonization" | "infiltrate" | "encourage_hate" | ... — see
  # Instance.Character.ActionImpl's action table).
  defp translate({:queue_travel_action, character_id, hops, action_type, target_id}) do
    jumps =
      Enum.map(hops, fn {from, to} ->
        %{"type" => "jump", "data" => %{"source" => from, "target" => to}}
      end)

    {:add_character_actions, character_id, jumps ++ [%{"type" => action_type, "data" => %{"target" => target_id}}]}
  end

  # Travel then a CHARACTER-targeted action ("assassination" | "conversion"):
  # like queue_travel_action but the terminal action carries the victim id.
  defp translate({:queue_travel_character_action, character_id, hops, action_type, target_id, target_character}) do
    jumps =
      Enum.map(hops, fn {from, to} ->
        %{"type" => "jump", "data" => %{"source" => from, "target" => to}}
      end)

    action = %{"type" => action_type, "data" => %{"target" => target_id, "target_character" => target_character}}
    {:add_character_actions, character_id, jumps ++ [action]}
  end

  # Move-only travel (defensive repositioning): lane hops, no terminal action.
  defp translate({:queue_travel, character_id, hops}) do
    jumps =
      Enum.map(hops, fn {from, to} ->
        %{"type" => "jump", "data" => %{"source" => from, "target" => to}}
      end)

    {:add_character_actions, character_id, jumps}
  end

  defp call(instance_id, player_id, payload) do
    case Game.call(instance_id, :player, player_id, payload) do
      {:error, reason} -> {:error, reason}
      other -> {:ok, other}
    end
  end
end
