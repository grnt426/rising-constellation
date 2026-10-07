# Decode instance snapshots and dump every Navarch's fleet, with the systems
# and players around it, as JSON lines: one <snapshot>.jsonl per snapshot. The
# input of bin/wave-fleets/mine_fleets.py (its <data_dir>/snapshots).
#
# Plain elixir, no mix: structs decode as maps, so any image with Elixir runs it.
#
#   docker run --rm -v <snapshots>:/snaps:ro -v <work>:/work --entrypoint elixir <rc image> \
#     /work/extract_fleets.exs /work/snapshots /snaps/<file>...

defmodule X do
  def num(v) when is_number(v), do: v
  def num(_), do: 0

  def val(%{value: v}), do: num(v)
  def val(v) when is_number(v), do: v
  def val(_), do: 0

  def s(nil), do: nil
  def s(v) when is_binary(v), do: v
  def s(v) when is_atom(v), do: Atom.to_string(v)
  def s(v) when is_number(v), do: v
  def s(v), do: inspect(v)

  def qlist(nil), do: []
  def qlist(l) when is_list(l), do: l
  def qlist(%{queue: q}), do: qlist(q)
  def qlist(%{q: {_, _} = q}), do: :queue.to_list(q)
  def qlist({a, b}) when is_list(a) and is_list(b), do: :queue.to_list({a, b})
  def qlist(_), do: []

  def system(sys) do
    owner = Map.get(sys, :owner)
    siege = Map.get(sys, :siege)

    %{
      k: "sys",
      id: sys.id,
      name: sys.name,
      type: s(Map.get(sys, :type)),
      status: s(sys.status),
      sector: Map.get(sys, :sector_id),
      owner: owner && Map.get(owner, :id),
      faction: owner && s(Map.get(owner, :faction)),
      def: val(Map.get(sys, :defense)),
      prod: val(Map.get(sys, :production)),
      pop: val(Map.get(sys, :population)),
      siege: is_map(siege) && %{type: s(Map.get(siege, :type)), by: Map.get(siege, :besieger_id)},
      xp: [
        val(Map.get(sys, :fighter_lvl)),
        val(Map.get(sys, :corvette_lvl)),
        val(Map.get(sys, :frigate_lvl)),
        val(Map.get(sys, :capital_lvl))
      ],
      yards:
        sys
        |> Map.get(:bodies, [])
        |> all_tiles()
        |> Enum.map(&s(Map.get(&1, :building_key)))
        |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "shipyard")))
    }
  end

  def all_tiles(bodies) do
    Enum.flat_map(bodies || [], fn b -> (Map.get(b, :tiles) || []) ++ all_tiles(Map.get(b, :bodies)) end)
  end

  def player(p) do
    %{
      k: "player",
      id: p.id,
      name: p.name,
      faction: s(p.faction),
      patents: Enum.map(Map.get(p, :patents) || [], &s/1),
      doctrines: Enum.map(Map.get(p, :doctrines) || [], &s/1),
      systems: Enum.map(Map.get(p, :stellar_systems) || [], & &1.id),
      dominions: Enum.map(Map.get(p, :dominions) || [], & &1.id)
    }
  end

  def character(c) do
    o = Map.get(c, :owner)
    army = Map.get(c, :army)

    tiles =
      ((army && Map.get(army, :tiles)) || [])
      |> Enum.filter(&(Map.get(&1, :ship_status) in [:filled, :planned] and is_map(Map.get(&1, :ship))))
      |> Enum.map(fn t ->
        units = Map.get(t.ship, :units) || []
        hull = units |> Enum.map(&num(Map.get(&1, :hull))) |> Enum.sum()
        alive = Enum.count(units, &(num(Map.get(&1, :hull)) > 0.001))

        %{
          t: t.id,
          key: s(t.ship.key),
          st: s(t.ship_status),
          lvl: num(Map.get(t.ship, :level)),
          hull: Float.round(hull * 1.0, 1),
          units: length(units),
          alive: alive
        }
      end)

    actions = Map.get(c, :actions)

    queue =
      actions
      |> qlist()
      |> Enum.map(fn a ->
        d = Map.get(a, :data) || %{}
        %{type: s(Map.get(a, :type)), target: Map.get(d, "target") || Map.get(d, :target), src: Map.get(d, "source") || Map.get(d, :source)}
      end)

    %{
      k: "char",
      id: c.id,
      name: Map.get(c, :name),
      type: s(c.type),
      status: s(c.status),
      level: num(Map.get(c, :level)),
      spec: s(Map.get(c, :specialization)),
      skills: Map.get(c, :skills) || [],
      owner: o && Map.get(o, :id),
      faction: o && s(Map.get(o, :faction)),
      system: Map.get(c, :system),
      action_status: s(Map.get(c, :action_status)),
      reaction: army && s(Map.get(army, :reaction)),
      raid: army && val(Map.get(army, :raid_coef)),
      invasion: army && val(Map.get(army, :invasion_coef)),
      maintenance: army && val(Map.get(army, :maintenance)),
      armada: Map.get(c, :armada) && Map.get(Map.get(c, :armada), :id),
      queue: queue,
      tiles: tiles
    }
  end

  # OTP 27 :json; atoms nil/true/false are handled by the encoder callback.
  def enc(term) do
    :json.encode(term, fn
      nil, _e -> "null"
      v, e -> :json.encode_value(v, e)
    end)
  end

  def run([out_dir | files]) do
    File.mkdir_p!(out_dir)

    Enum.each(files, fn file ->
      base = Path.basename(file)
      snap = file |> File.read!() |> :erlang.binary_to_term()
            agents = Map.get(snap, :agents_data) || []

      rows =
        Enum.flat_map(agents, fn a ->
          st = Map.get(a, :state)
          st = if is_map(st), do: st, else: %{}
          data = Map.get(st, :data)
          type = Map.get(st, :type)

          cond do
            type == :stellar_system and is_map(data) -> [system(data)]
            type == :player and is_map(data) -> [player(data)]
            type == :character and is_map(data) and Map.get(data, :type) == :admiral -> [character(data)]
            type == :time and is_map(data) -> [%{k: "time", now: inspect(Map.get(data, :now)), keys: Enum.map(Map.keys(data), &s/1), raw: inspect(Map.drop(data, [:__struct__]), limit: 40)}]
            true -> []
          end
        end)

      meta = %{k: "meta", file: base}
      out = Path.join(out_dir, base <> ".jsonl")
      body = Enum.map([meta | rows], fn r -> [enc(r), "\n"] end)
      File.write!(out, body)
      IO.puts("#{base}: #{length(rows)} rows")
    end)
  end
end

X.run(System.argv())
