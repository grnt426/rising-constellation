defmodule RcBot.Policy.Dumb do
  @moduledoc """
  Minimum-viable stress-test policy.

  ## v1 scope (this file)

  Fires the smallest set of actions that reliably generate server load
  from a fresh player state:

    * Hire one affordable character from `character_deck` per burst.
      Cheap, always available early-game, exercises the full
      player-channel → player-agent → broadcast loop.

  That's it. We deliberately punt on buildings, ships, patents,
  doctrines, and colonization in v1 because each requires either
  system/tile knowledge or faction-specific keys we don't yet have a
  clean way to enumerate from the broadcast.

  ## v2 directions (NOT in this file)

    * `order_building` once we can enumerate legal tiles for an owned
      system. Weighted by 1/build_time per the user's stress-skew note.
    * `purchase_patent` once we can fetch the per-faction patent tree.
    * Colonization — see `bot_colonization_strategy.md` in memory.
      Multi-step pipeline (research lex → recruit Navarchs → scout →
      load colony ship → dispatch). Do NOT cheat-grant scouted system
      knowledge: scouting movement IS legitimate sim load.
  """

  @behaviour RcBot.Policy

  @impl true
  def decide_actions(nil), do: []

  def decide_actions(%{} = player) do
    []
    |> maybe_hire_character(player)
  end

  # Pick the cheapest affordable character that's off-cooldown AND
  # whose type has a free slot. Without the slot check the agent
  # returns :character_unavailable on every attempt, which spams the
  # bot_events log without exercising anything useful.
  defp maybe_hire_character(actions, player) do
    credit = get_in(player, ["credit", "value"]) || 0
    free_slots = compute_free_slots(player)

    candidate =
      player
      |> Map.get("character_deck", [])
      |> Enum.filter(fn entry ->
        type = get_in(entry, ["character", "type"])

        is_nil(entry["cooldown"]) and
          is_integer(get_in(entry, ["character", "id"])) and
          (get_in(entry, ["character", "credit_cost"]) || 0) <= credit and
          get_in(entry, ["character", "status"]) == "in_deck" and
          Map.get(free_slots, type, 0) > 0
      end)
      |> Enum.sort_by(fn entry -> get_in(entry, ["character", "credit_cost"]) || 0 end)
      |> List.first()

    case candidate do
      nil ->
        actions

      entry ->
        id = get_in(entry, ["character", "id"])
        actions ++ [{"hire_character", %{"character" => %{"id" => id}}, :player}]
    end
  end

  # Returns %{"admiral" => N, "spy" => N, "speaker" => N} where N is
  # the remaining slot count. The server's hire validates against
  # max_admirals/max_spies/max_speakers; mirror that here so we don't
  # ask for hires we know will fail.
  defp compute_free_slots(player) do
    counts =
      player
      |> Map.get("characters", [])
      |> Enum.frequencies_by(fn c -> c["type"] end)

    %{
      "admiral" => max_value(player, "max_admirals") - Map.get(counts, "admiral", 0),
      "spy" => max_value(player, "max_spies") - Map.get(counts, "spy", 0),
      "speaker" => max_value(player, "max_speakers") - Map.get(counts, "speaker", 0)
    }
  end

  defp max_value(player, key) do
    case get_in(player, [key, "value"]) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end
end
