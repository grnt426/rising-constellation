defmodule Instance.StellarSystem.Character do
  use TypedStruct
  use Util.MakeEnumerable

  alias Instance.StellarSystem

  def jason(), do: []

  typedstruct enforce: false do
    field(:id, integer())
    field(:type, atom())
    field(:name, String.t())
    field(:level, integer())
    field(:owner, %Instance.Character.Player{})
    field(:protection, integer())
    field(:determination, integer())
    field(:cover, float() | nil)
    # armada grouping key — every viewer of the system sees which
    # visible Navarchs stand in formation together (2026-08-20 design
    # change from owner-only; the armada NAME still rides only the
    # owner's roster payload)
    field(:armada_id, integer() | nil)
  end

  def convert(character) do
    cover =
      if character.spy,
        do: character.spy.cover.value,
        else: nil

    armada_id =
      case Map.get(character, :armada) do
        nil -> nil
        armada -> Map.get(armada, :id)
      end

    %StellarSystem.Character{
      id: character.id,
      type: character.type,
      name: character.name,
      level: character.level,
      owner: character.owner,
      protection: character.protection,
      determination: character.determination,
      cover: cover,
      armada_id: armada_id
    }
  end

  def obfuscate(%StellarSystem.Character{} = character, visibility_level) do
    new_character = %StellarSystem.Character{}

    fields_levels = %{
      2 => [:id, :type, :name, :level, :owner, :armada_id],
      3 => [],
      4 => [:determination],
      5 => [:protection],
      6 => [:cover]
    }

    # filter fields
    Enum.reduce(fields_levels, new_character, fn {level, fields}, new_character ->
      if level <= visibility_level do
        Enum.reduce(fields, new_character, fn field, new_character ->
          Map.put(new_character, field, Map.get(character, field))
        end)
      else
        new_character
      end
    end)
  end
end
