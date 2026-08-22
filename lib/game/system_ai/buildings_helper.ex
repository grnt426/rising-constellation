defmodule SystemAI.BuildingsHelper do
  require Logger

  # Wonder-tier buildings (Monolith, Metamaterials Factory) are reserved for
  # player-ordered construction; the system AI must never build or upgrade them.
  @excluded_building_keys [:monument_dome, :high_factory_dome]

  def excluded_building_keys, do: @excluded_building_keys

  def get_all_buildings(instance_id) do
    Data.Querier.all(Data.Game.Building, instance_id)
  end

  def get_biome_buildings(biome_key, instance_id) do
    all_buildings =
      get_all_buildings(instance_id)
      |> Enum.reject(fn building -> building.key in @excluded_building_keys end)

    case biome_key do
      :open -> all_buildings |> Enum.filter(fn building -> building.biome == :open end)
      :dome -> all_buildings |> Enum.filter(fn building -> building.biome == :dome end)
      :orbital -> all_buildings |> Enum.filter(fn building -> building.biome == :orbital end)
    end
  end
end
