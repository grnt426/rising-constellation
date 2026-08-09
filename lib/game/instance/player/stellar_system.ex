defmodule Instance.Player.StellarSystem do
  use TypedStruct
  use Util.MakeEnumerable

  alias Instance.Character.Spy
  alias Instance.Player
  alias Instance.StellarSystem.ProductionQueue
  alias Spatial.Position

  def jason(), do: []

  typedstruct enforce: true do
    field(:id, integer())
    field(:position, %Position{})
    field(:sector_id, integer())
    field(:name, String.t())
    field(:type, atom())
    field(:status, atom())
    field(:governor, integer() | nil)
    field(:characters, [%Instance.StellarSystem.Character{}] | [])
    field(:queue, integer())
    field(:queue_remaining_time, float() | atom())
    field(:workforce, integer())
    field(:habitation, integer())
    field(:production, float())
    field(:technology, float())
    field(:ideology, float())
    field(:credit, float())
    field(:happiness, float())
    field(:defense, float())
    field(:radar, float())
    field(:siege, atom() | nil)
  end

  def convert(system) do
    %Player.StellarSystem{
      id: system.id,
      position: system.position,
      sector_id: system.sector_id,
      name: system.name,
      type: system.type,
      status: system.status,
      governor: system.governor,
      characters: visible_characters(system),
      queue: Queue.length(system.queue.queue),
      queue_remaining_time: ProductionQueue.get_total_remaining_time(system),
      workforce: system.workforce,
      habitation: system.habitation.value,
      production: system.production.value,
      technology: system.technology.value,
      ideology: system.ideology.value,
      credit: system.credit.value,
      happiness: system.happiness.value,
      defense: system.defense.value,
      radar: system.radar.value,
      siege: system.siege
    }
  end

  # This struct goes over the owner's player channel, so it must not reveal
  # more than the sanctioned visibility rules: foreign Erased still under
  # cover are removed entirely, and cover is faction-private — the owning
  # faction keeps it, everyone else gets nil (the faction view gates it at
  # level 6 for the same reason). Navarchs/Siderians carry no cover and the
  # vis-5 field set retains everything else this summary struct holds, so
  # they pass through whole. Without this the raw copies leaked hidden
  # spies (and their exact cover values) to anyone reading the socket.
  def visible_characters(system) do
    owner_faction_id = system.owner && system.owner.faction_id

    system.characters
    |> Enum.reject(fn c ->
      c.type == :spy and c.owner.faction_id != owner_faction_id and
        Spy.undercover?(c.cover, system.instance_id)
    end)
    |> Enum.map(fn c ->
      obfuscated = Instance.StellarSystem.Character.obfuscate(c, 5)

      if c.type == :spy and c.owner.faction_id == owner_faction_id,
        do: %{obfuscated | cover: c.cover},
        else: obfuscated
    end)
  end
end
