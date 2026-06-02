defmodule Instance.Faction.Character do
  use TypedStruct
  use Util.MakeEnumerable

  alias Instance.Faction
  alias Instance.Character
  alias Instance.Character.Tile

  def jason(), do: []

  typedstruct enforce: false do
    field(:id, integer())
    field(:status, atom())
    field(:type, atom())
    field(:specialization, atom())
    field(:skills, [integer()])
    field(:age, integer())
    field(:culture, atom())
    field(:name, String.t())
    field(:gender, atom())
    field(:illustration, String.t())
    field(:level, integer())
    field(:experience, %Core.DynamicValue{})
    field(:protection, integer())
    field(:determination, integer())
    field(:owner, %Character.Player{} | nil)
    field(:system, integer() | nil)
    field(:action_status, atom())
    field(:on_strike, boolean())
    field(:army, %Character.Army{} | nil)
    field(:spy, %Character.Spy{} | nil)
    field(:speaker, %Character.Speaker{} | nil)
  end

  @doc """
  Reduce a `%Character.Character{}` to the subset of fields that may
  reach a viewer at the given visibility level.

  Stage 8 (info disclosure) fixes:

    * **F4** — Doctrine/Patent/Tradition identifiers used to leak via
      the `details` map on each nested `%Core.Value{}` field inside
      `character.army.{maintenance, repair_coef, invasion_coef, raid_coef}`
      etc. The system-level obfuscate already strips details at
      `visibility_level < 5`, but did not recurse into character
      substructs. We now strip details on every nested `Core.Value`/
      `Core.DynamicValue` inside the army/spy/speaker substruct when
      the viewer is either non-own-faction or below trust level 5.

    * **F8** — At visibility 5 (which a non-own-faction enemy can
      reach by holding 3 informers on the host system) the previous
      code unconditionally included `:action_status` on the
      `%Faction.Character{}`, telling the enemy player exactly what
      action the character is currently performing. The UI only
      renders `action_status` for own characters. We now drop
      `:action_status` for non-own-faction viewers at vis=5.

    * **F3** — When a spy attack's `became_discovered? == false`, the
      attack action wants to send the defender a notification that
      does NOT identify the spy. Previously the lowest visibility
      filter was tier 2, which still leaked id+name+illustration+owner.
      A new **anonymous tier 1** is added that fills only `[:type, :level]`
      — enough for the UI to render "an enemy spy of level N" without
      revealing identity. Tier 1 also suppresses the army/spy/speaker
      substruct entirely (gated on `visibility_level >= 2`).

  The optional `viewer_faction_key` argument is the asking faction's
  atom key (e.g. `state.data.key` inside `Faction.Agent`). When `nil`
  (the safe default used by `Notification.Character.*`), the viewer
  is treated as non-own-faction and the strictest stripping applies —
  which is correct for defender notifications.
  """
  def obfuscate(character, visibility_level, viewer_faction_key \\ nil)

  def obfuscate(%Character.Character{} = character, visibility_level, viewer_faction_key) do
    is_own_faction =
      viewer_faction_key != nil and
        is_map(character.owner) and
        Map.get(character.owner, :faction) == viewer_faction_key

    new_character = %Faction.Character{}

    fields_levels = %{
      # Stage 8 F3 — anonymous tier: only :type and :level reach the
      # wire, enough to render "an enemy spy of level N" without
      # identifying the character or its owner.
      1 => [:type, :level],
      2 => [:id, :status, :type, :name, :illustration, :level, :owner, :system],
      3 => [:gender],
      4 => [:specialization, :age, :culture],
      5 => [:skills, :experience, :protection, :determination, :action_status, :on_strike]
    }

    # Stage 8 F8 — at vis=5, :action_status is faction-internal intent
    # data (it reveals what attack the character is currently mid-cast on).
    # Drop it for non-own-faction viewers even at the top visibility tier.
    fields_levels =
      if visibility_level == 5 and not is_own_faction do
        Map.update!(fields_levels, 5, fn fields -> fields -- [:action_status] end)
      else
        fields_levels
      end

    # filter fields
    new_character =
      Enum.reduce(fields_levels, new_character, fn {level, fields}, new_character ->
        if level <= visibility_level do
          Enum.reduce(fields, new_character, fn field, new_character ->
            Map.put(new_character, field, Map.get(character, field))
          end)
        else
          new_character
        end
      end)

    # Substructs are suppressed below vis=2 so the F3 anonymous tier
    # carries no army/spy/speaker payload at all.
    include_substructs? = visibility_level >= 2

    # filter army if admiral
    new_character =
      if include_substructs? and character.type == :admiral and character.status == :on_board,
        do: %{new_character | army: obfuscate_army(character.army, visibility_level, is_own_faction)},
        else: new_character

    # filter spy if spy
    new_character =
      if include_substructs? and character.type == :spy and character.status == :on_board,
        do: %{new_character | spy: obfuscate_spy(character.spy, visibility_level, is_own_faction)},
        else: new_character

    # filter speaker if speaker
    if include_substructs? and character.type == :speaker and character.status == :on_board,
      do: %{new_character | speaker: obfuscate_speaker(character.speaker, visibility_level, is_own_faction)},
      else: new_character
  end

  def obfuscate_army(army, visibility_level, is_own_faction \\ false)

  def obfuscate_army(%Character.Army{} = army, visibility_level, is_own_faction) do
    fields_levels = %{
      4 => [:maintenance],
      5 => [:reaction, :repair_coef, :invasion_coef, :raid_coef]
    }

    # filter fields
    new_army =
      Enum.reduce(fields_levels, %{}, fn {level, fields}, new_army ->
        if level <= visibility_level do
          Enum.reduce(fields, new_army, fn field, new_army ->
            Map.put(new_army, field, Map.get(army, field))
          end)
        else
          new_army
        end
      end)

    # Stage 8 F4 — strip nested Core.Value.details on each resource
    # field when the viewer is non-own-faction or below vis=5. Mirrors
    # the system-level strip in StellarSystem.obfuscate.
    new_army = strip_value_details(new_army, visibility_level, is_own_faction)

    tiles = Enum.map(army.tiles, fn tile -> Tile.obfuscate(tile, visibility_level) end)
    Map.put(new_army, :tiles, tiles)
  end

  def obfuscate_spy(spy, visibility_level, is_own_faction \\ false)

  def obfuscate_spy(%Character.Spy{} = spy, visibility_level, is_own_faction) do
    # cover will never be shown
    fields_levels = %{
      5 => [:infiltrate_coef, :sabotage_coef, :assassination_coef],
      6 => [:cover]
    }

    new_spy =
      Enum.reduce(fields_levels, %{}, fn {level, fields}, new_spy ->
        if level <= visibility_level do
          Enum.reduce(fields, new_spy, fn field, new_spy ->
            Map.put(new_spy, field, Map.get(spy, field))
          end)
        else
          new_spy
        end
      end)

    # Stage 8 F4 — strip details on infiltrate/sabotage/assassination
    # coefficients (each is a %Core.Value{}) for cross-faction viewers.
    strip_value_details(new_spy, visibility_level, is_own_faction)
  end

  def obfuscate_speaker(speaker, visibility_level, is_own_faction \\ false)

  def obfuscate_speaker(%Character.Speaker{} = speaker, visibility_level, is_own_faction) do
    # cooldown will never be shown
    fields_levels = %{
      5 => [:make_dominion_coef, :encourage_hate_coef, :conversion_coef],
      6 => [:cooldown]
    }

    new_speaker =
      Enum.reduce(fields_levels, %{}, fn {level, fields}, new_speaker ->
        if level <= visibility_level do
          Enum.reduce(fields, new_speaker, fn field, new_speaker ->
            Map.put(new_speaker, field, Map.get(speaker, field))
          end)
        else
          new_speaker
        end
      end)

    # Stage 8 F4 — same details strip for speaker coefficients.
    strip_value_details(new_speaker, visibility_level, is_own_faction)
  end

  # Stage 8 F4 helper. Walks an obfuscated substruct (army / spy /
  # speaker) and, for every `%Core.Value{}` / `%Core.DynamicValue{}`
  # field, replaces `:details` with an empty map. Only applied when
  # the viewer is either non-own-faction OR below vis=5 — at vis=5
  # for own-faction viewers we keep the details intact because the
  # UI tooltip needs them to explain "where this maintenance number
  # came from".
  defp strip_value_details(substruct, visibility_level, is_own_faction) do
    if visibility_level < 5 or not is_own_faction do
      Enum.reduce(substruct, substruct, fn {key, value}, acc ->
        if is_map(value) and Enum.member?([:advanced, :dynamic], Util.Type.typeof_value(value)),
          do: Map.put(acc, key, Map.put(value, :details, %{})),
          else: acc
      end)
    else
      substruct
    end
  end
end
