defmodule Instance.Character.LockMerge do
  @moduledoc """
  Reconciles a character agent's state with the result of an orchestrator
  hook.

  While the orchestrator runs the head action's start/finish hook, the
  agent keeps receiving writes: a ship completes in a shipyard, the owner
  changes the fleet's reaction, an armada or bonus update arrives, training
  XP drips in, another agent's fight reports this one's losses. The hook
  works on the copy it was handed when the queue locked, so its result
  knows none of that — replacing the agent's state with it silently undid
  every one of those writes.

  This is a three-way merge per field of the character:

    * `base`   — the copy the orchestrator was handed (queue locked);
    * `ours`   — the agent's state now: base + the writes of the window;
    * `theirs` — the hook's result: base + the hook's changes.

  A field only one side changed takes that side. Fields both changed:

    * `:actions` — the hook's (it owns the queue; player edits are refused
      while locked);
    * `:army` — tile by tile, then field by field (a ship built during the
      window and fight damage the hook dealt elsewhere both stand); a tile
      both sides changed goes to the hook;
    * `:experience` — the hook's value plus what the window added;
    * plain maps (`:bonuses`) — key by key;
    * anything else — the hook's, reported as a conflict so it shows in
      the logs.
  """

  alias Instance.Character.Army

  @doc """
  Returns `{merged, changed_by_window, conflicts}`: the merged character,
  the fields whose final value came from the window's writes (derived
  values may need recomputing), and the fields both sides changed
  differently (resolved for the hook) — excluding the expected `:actions`.
  """
  def merge(base, ours, theirs) do
    fields = Enum.uniq(keys(base) ++ keys(ours) ++ keys(theirs))

    Enum.reduce(fields, {theirs, [], []}, fn field, {acc, changed, conflicts} ->
      b = Map.get(base, field)
      o = Map.get(ours, field)
      t = Map.get(theirs, field)

      cond do
        o == b or o == t ->
          {acc, changed, conflicts}

        t == b ->
          {Map.put(acc, field, o), [field | changed], conflicts}

        true ->
          case merge_field(field, b, o, t) do
            {:merged, value} -> {Map.put(acc, field, value), [field | changed], conflicts}
            {:theirs, _} when field == :actions -> {acc, changed, conflicts}
            {:theirs, _} -> {acc, changed, [field | conflicts]}
          end
      end
    end)
  end

  defp keys(%_{} = struct), do: struct |> Map.from_struct() |> Map.keys()
  defp keys(map) when is_map(map), do: Map.keys(map)

  defp merge_field(:actions, _b, _o, t), do: {:theirs, t}

  defp merge_field(:army, %Army{} = b, %Army{} = o, %Army{} = t), do: {:merged, merge_army(b, o, t)}

  defp merge_field(:experience, %{value: bv} = b, %{value: ov}, %{value: tv} = t)
       when is_number(bv) and is_number(ov) and is_number(tv) and is_map(b),
       do: {:merged, %{t | value: tv + (ov - bv)}}

  defp merge_field(_field, b, o, t) when is_map(b) and is_map(o) and is_map(t) and not is_struct(t),
    do: {:merged, merge_map(b, o, t)}

  defp merge_field(_field, _b, _o, t), do: {:theirs, t}

  # Per field of the army; tiles per tile id.
  defp merge_army(b, o, t) do
    b
    |> Map.from_struct()
    |> Map.keys()
    |> Enum.reduce(t, fn
      :tiles, acc ->
        %{acc | tiles: merge_tiles(b.tiles, o.tiles, t.tiles)}

      field, acc ->
        {bv, ov, tv} = {Map.get(b, field), Map.get(o, field), Map.get(t, field)}
        if ov != bv and tv == bv, do: Map.put(acc, field, ov), else: acc
    end)
  end

  defp merge_tiles(b, o, t) do
    base = Map.new(b, &{&1.id, &1})
    ours = Map.new(o, &{&1.id, &1})

    Enum.map(t, fn tile ->
      bt = Map.get(base, tile.id)
      ot = Map.get(ours, tile.id)
      if ot != nil and ot != bt and tile == bt, do: ot, else: tile
    end)
  end

  defp merge_map(b, o, t) do
    (Map.keys(b) ++ Map.keys(o) ++ Map.keys(t))
    |> Enum.uniq()
    |> Enum.reduce(t, fn key, acc ->
      {bv, ov, tv} = {Map.get(b, key), Map.get(o, key), Map.get(t, key)}

      cond do
        ov == bv -> acc
        tv == bv and ov == nil -> Map.delete(acc, key)
        tv == bv -> Map.put(acc, key, ov)
        true -> acc
      end
    end)
  end
end
