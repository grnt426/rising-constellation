defmodule Instance.Player.SystemUpdateBatch do
  @moduledoc """
  Coalesces `{:update_system, _}` / `{:update_dominion, _}` casts for a player
  that owns a very large empire.

  Every owned system casts its full state to the owner's player agent whenever
  it changes, and applying one update recomputes the player's bonuses across
  every owned system. That is quadratic in empire size: the Wave Defense
  Rebellion at ~190 systems spent most of the node's work there. Buffering the
  updates for a short window and applying the latest state of each system once
  gives the same end result — `Player.compute_bonus/1` rebuilds every value
  from the current summaries, so N sequential updates and one batched update
  land on identical state — at one recomputation per window.

  Only bot-held (Wave Defense) players batch today; human players keep the
  immediate per-update path, so their UI never lags.
  """

  @doc "True when this player's system updates should be coalesced."
  def batching?(instance_id, faction), do: Wave.Config.bot_faction?(instance_id, faction)

  @doc "Coalescing window in wall milliseconds."
  def window_ms(instance_id) do
    case Wave.Config.knob(instance_id, "system_update_batch_ms", 500) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> 500
    end
  end

  @doc "Add an update; a later update of the same system replaces the earlier one."
  def add(pending, kind, %{id: id} = system) when kind in [:system, :dominion],
    do: Map.put(pending, {kind, id}, system)

  @doc "Split pending updates into `{systems, dominions}`."
  def split(pending) do
    Enum.reduce(pending, {[], []}, fn
      {{:system, _}, system}, {systems, dominions} -> {[system | systems], dominions}
      {{:dominion, _}, system}, {systems, dominions} -> {systems, [system | dominions]}
    end)
  end
end
