defmodule Instance.StellarSystem.StellarBody do
  use TypedStruct
  use Util.MakeEnumerable

  def jason(), do: []

  typedstruct enforce: true do
    field(:id, integer())
    field(:uid, String.t())
    field(:type, atom())
    field(:name, String.t())
    field(:industrial_factor, integer() | :hidden)
    field(:technological_factor, integer() | :hidden)
    field(:activity_factor, integer() | :hidden)
    field(:population, integer() | :hidden)
    field(:bodies, [%Instance.StellarSystem.StellarBody{}] | [])
    field(:tiles, [%Instance.StellarSystem.Tile{}] | [])
  end

  def new(id, prefix_name, instance_id, type, parent_id \\ nil) do
    bodies_data =
      Data.Querier.all(Data.Game.StellarBody, instance_id)
      |> Enum.filter(fn body -> body.type == type end)

    body_data = Game.call(instance_id, :rand, :master, {:random, bodies_data})

    # World-gen mutators (on_galaxy_spawn). These never touch the RNG stream —
    # the draws below still happen, only their results are overridden — so a
    # body generated without these mutators is identical to vanilla. See
    # Data.Game.Mutator. Lookups default to "no effect" outside a live
    # instance, so this is also safe to call from tooling/tests.
    factor_override = Instance.Mutators.gen_factor_override(instance_id, type)
    extra_tiles = Instance.Mutators.extra_tiles(instance_id)

    {name, uid, bodies} =
      case type do
        :primary ->
          name = "#{prefix_name} #{Util.RomanNumerals.convert(id)}"

          bodies =
            0..Game.call(instance_id, :rand, :master, {:random, body_data.gen_subbody_number})
            |> Enum.filter(fn i -> i != 0 end)
            |> Enum.map(fn i -> new(i, name, instance_id, :secondary, id) end)

          {name, "#{id}", bodies}

        :secondary ->
          name = "#{prefix_name}.#{String.at(to_string(Enum.to_list(?a..?z)), id - 1)}"
          {name, "#{parent_id}-#{id}", []}
      end

    tile_count =
      Game.call(instance_id, :rand, :master, {:random, body_data.gen_tiles_number}) + extra_tiles

    tiles =
      0..tile_count
      |> Enum.filter(fn i -> i != 0 end)
      |> Enum.map(fn i -> Instance.StellarSystem.Tile.new(i, type) end)

    # Factor rolls, drawn in their original order (industrial, technological,
    # activity) to keep the RNG stream identical; the override is applied to
    # the rolled result, not to the draw.
    industrial = Game.call(instance_id, :rand, :master, {:random, body_data.gen_ind_factor_number})
    technological = Game.call(instance_id, :rand, :master, {:random, body_data.gen_tec_factor_number})
    activity = Game.call(instance_id, :rand, :master, {:random, body_data.gen_act_factor_number})

    %Instance.StellarSystem.StellarBody{
      id: id,
      uid: uid,
      type: body_data.key,
      name: name,
      industrial_factor: Data.Game.Mutator.apply_factor(industrial, factor_override, body_data.gen_ind_factor_number),
      technological_factor:
        Data.Game.Mutator.apply_factor(technological, factor_override, body_data.gen_tec_factor_number),
      activity_factor: Data.Game.Mutator.apply_factor(activity, factor_override, body_data.gen_act_factor_number),
      population: 0,
      bodies: bodies,
      tiles: tiles
    }
  end

  def new_from_model(id, body, prefix_name, type, parent_id \\ nil) do
    key = String.to_existing_atom(body["key"])

    {name, uid, bodies} =
      case type do
        :primary ->
          name = "#{prefix_name} #{Util.RomanNumerals.convert(id)}"

          bodies =
            body["subbodies"]
            |> Enum.with_index()
            |> Enum.map(fn {body, i} ->
              Instance.StellarSystem.StellarBody.new_from_model(i + 1, body, name, :secondary, id)
            end)

          {name, "#{id}", bodies}

        :secondary ->
          name = "#{prefix_name}.#{String.at(to_string(Enum.to_list(?a..?z)), id - 1)}"
          {name, "#{parent_id}-#{id}", []}
      end

    tiles =
      0..body["tiles"]
      |> Enum.filter(fn i -> i != 0 end)
      |> Enum.map(fn i -> Instance.StellarSystem.Tile.new(i, type) end)

    %Instance.StellarSystem.StellarBody{
      id: id,
      uid: uid,
      type: key,
      name: name,
      industrial_factor: body["ind_factor"],
      technological_factor: body["tec_factor"],
      activity_factor: body["act_factor"],
      population: 0,
      bodies: bodies,
      tiles: tiles
    }
  end
end
