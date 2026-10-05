defmodule Instance.Faction.Sighting do
  use TypedStruct
  use Util.MakeEnumerable

  alias Instance.Faction.Sighting
  alias Spatial.Position

  # An enemy a faction member reported to the faction: a fleet on the
  # S.L.S.D. (`kind: "fleet"`) or an agent standing in a system
  # (`kind: "agent"`). A chat chip (`[[spot:<id>]]`) points at it.
  #
  # A sighting is "live" for as long as the faction can still see the
  # thing it reported, then turns "lost" ONCE and stays so: a chip read
  # hours later says by itself whether it is still worth a look. A lost
  # sighting never comes back to life, even if the same fleet returns —
  # that would tell the faction which anonymous blip is which.
  #
  # Strings rather than atoms throughout: sightings are snapshotted with
  # the faction, and the safe decode refuses atoms the BEAM has not met.

  # Internal fields, never sent to a client: the radar shows a fleet as an
  # anonymous blip, so the identity behind a fleet sighting stays here.
  # (Where the fleet is heading is no secret: every blip says it.)
  def jason(), do: [except: [:character_id, :target_position]]

  typedstruct enforce: true do
    field(:id, integer())
    field(:kind, String.t())
    field(:character_id, integer())
    # Faction key of the sighted fleet / agent.
    field(:faction, String.t())
    # "admiral" | "spy" | "speaker". A blip is always a Navarch: only
    # their fleets show on the S.L.S.D.
    field(:agent_type, String.t())
    # Agents only (a blip has no name): the agent and its owner as the
    # system view showed them to the reporter.
    field(:name, String.t() | nil)
    field(:owner, String.t() | nil)
    # Fleet: the system it was flying to (nil when unknown).
    # Agent: the system it stood in.
    field(:system_id, integer() | nil)
    # Where it was last seen: followed while a fleet is live, frozen once
    # lost.
    field(:position, %Position{} | nil)
    field(:target_position, %Position{} | nil)
    # "live" | "lost"
    field(:status, String.t())
    # Why it was lost, as far as the faction could tell by itself:
    #   fleet: "arrived" | "out_of_range"
    #   agent: "hidden" (no longer visible there: left, or back under
    #          cover) | "no_contact" (the faction lost its view of the
    #          system) | "untracked" (pushed out by newer reports)
    field(:reason, String.t() | nil)
    field(:reporter_id, integer())
    field(:spotted_at, integer())
    field(:lost_at, integer() | nil)
    # The chat message that announced it.
    field(:message_id, integer() | nil)
  end

  def live?(%{status: "live"}), do: true
  def live?(_sighting), do: false

  def fleet(id, blip, reporter_id, message_id) do
    %Sighting{
      id: id,
      kind: "fleet",
      character_id: blip.character_id,
      faction: to_string(blip.faction),
      agent_type: "admiral",
      name: nil,
      owner: nil,
      system_id: Map.get(blip, :target_system_id),
      position: blip.position,
      target_position: Map.get(blip, :target_position),
      status: "live",
      reason: nil,
      reporter_id: reporter_id,
      spotted_at: now(),
      lost_at: nil,
      message_id: message_id
    }
  end

  # `character` is the entry of the system's character list as the
  # faction is allowed to see it (Instance.StellarSystem.Character).
  def agent(id, character, system, reporter_id, message_id) do
    %Sighting{
      id: id,
      kind: "agent",
      character_id: character.id,
      faction: to_string(character.owner.faction),
      agent_type: to_string(character.type),
      name: character.name,
      owner: character.owner.name,
      system_id: system.id,
      position: system.position,
      target_position: nil,
      status: "live",
      reason: nil,
      reporter_id: reporter_id,
      spotted_at: now(),
      lost_at: nil,
      message_id: message_id
    }
  end

  # A live fleet sighting against the blip the radar still shows for it.
  # The blip of a fleet that has moved on to another leg means it reached
  # the system it was reported flying to. An unknown leg on either side
  # proves nothing and keeps the sighting as it is.
  def track_fleet(%Sighting{status: "live", kind: "fleet"} = sighting, blip) do
    target = Map.get(blip, :target_system_id)

    if is_nil(sighting.system_id) or is_nil(target) or target == sighting.system_id,
      do: %{sighting | position: blip.position},
      else: lose(sighting, "arrived")
  end

  def lose(sighting, reason)

  # A fleet that arrived is at its destination: that is where the chip
  # should take the player.
  def lose(%Sighting{status: "live", target_position: %Position{} = target} = sighting, "arrived") do
    %{sighting | status: "lost", reason: "arrived", position: target, lost_at: now()}
  end

  def lose(%Sighting{status: "live"} = sighting, reason) when is_binary(reason) do
    %{sighting | status: "lost", reason: reason, lost_at: now()}
  end

  def lose(%Sighting{} = sighting, _reason), do: sighting

  defp now(), do: :os.system_time(:seconds)
end
