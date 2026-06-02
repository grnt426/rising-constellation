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

  # Pick the cheapest affordable character that's off-cooldown. Cheapest
  # first means we exhaust the deck over multiple bursts rather than
  # blowing the budget on one big hire.
  defp maybe_hire_character(actions, player) do
    credit = get_in(player, ["credit", "value"]) || 0

    candidate =
      player
      |> Map.get("character_deck", [])
      |> Enum.filter(fn entry ->
        is_nil(entry["cooldown"]) and
          is_integer(get_in(entry, ["character", "id"])) and
          (get_in(entry, ["character", "credit_cost"]) || 0) <= credit and
          get_in(entry, ["character", "status"]) == "in_deck"
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
end
