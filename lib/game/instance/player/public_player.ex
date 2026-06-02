defmodule Instance.Player.PublicPlayer do
  use TypedStruct
  use Util.MakeEnumerable

  alias Instance.Player

  def jason(), do: []

  typedstruct enforce: true do
    field(:id, integer())
    field(:account_id, integer())
    field(:faction_id, integer())
    field(:faction, atom())
    field(:is_dead, boolean())
    field(:is_active, boolean())
    field(:avatar, String.t())
    field(:name, String.t())
    field(:registration_id, integer())
    field(:age, integer())
    field(:description, String.t())
    field(:elo, integer())
    field(:full_name, String.t())
    field(:long_description, String.t())
  end

  def new(%Player.Player{} = player, profile) do
    %Player.PublicPlayer{
      id: player.id,
      account_id: player.account_id,
      faction_id: player.faction_id,
      faction: player.faction,
      is_dead: player.is_dead,
      is_active: player.is_active,
      avatar: player.avatar,
      name: player.name,
      registration_id: player.registration_id,
      age: profile.age,
      description: profile.description,
      # Stage 8 F7 — round ELO at the wire boundary. ProfileCard.vue
      # renders this as `{{ profile.elo | integer }}` so the wire
      # carrying a raw float gave a precision asymmetry between UI
      # players and wire readers. See rankings_view.ex for the
      # mirror fix on the standings endpoint.
      elo: round(profile.elo),
      full_name: profile.full_name,
      long_description: profile.long_description
    }
  end
end
