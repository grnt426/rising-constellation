defmodule Instance.StellarSystem.Station do
  use TypedStruct
  use Util.MakeEnumerable

  alias Instance.StellarSystem.Station

  @moduledoc """
  The system's orbital station: a 2×2 grid of faction-government build
  slots, separate from body tiles. Buildings here are ordered by a
  cabinet seat, paid from the faction treasury, and may span several
  slots (see docs/faction-buildings.md).

  This struct is purely the physical state (what stands where, what is
  being built); authority, costs, and upkeep live on the faction
  government. `:station` is a late-added field on the snapshotted
  StellarSystem struct — callers must reach it with `Map.get` and
  lazy-create via `StellarSystem.get_station/1`, never dot-access.

  Slots are indexed row-major on the 2×2 grid:

      0 1
      2 3

  A building's shape is `%{cols, rows}`; its anchor is the top-left
  slot it covers.

  Building entries: `%{id, key, level, faction_id, slots, status}`
  with status `:built | :disabled` (disabled = the owning faction lost
  direct player control of the system; the structure stands but its
  command codes don't answer — no benefits, no upkeep, unusable by the
  captor).

  Construction: `%{building_id, key, level, faction_id, slots,
  total_labor, remaining_labor, kind: :new | :upgrade}` — advanced by
  the system tick at the system's production rate, on a track parallel
  to the player's own production queue.
  """

  @cols 2
  @rows 2

  def jason(), do: []

  typedstruct enforce: true do
    field(:buildings, [map()], default: [])
    field(:construction, map() | nil, default: nil)
    # All-or-nothing faction upkeep power state, pushed by the faction
    # agent (false = treasury could not cover upkeep; no benefits).
    field(:powered, boolean(), default: true)
    field(:next_building_id, integer(), default: 1)
  end

  def new() do
    %Station{buildings: [], construction: nil, powered: true, next_building_id: 1}
  end

  def cols(), do: @cols
  def rows(), do: @rows

  @doc """
  The slot indexes a `%{cols, rows}` shape covers when anchored at
  `anchor` (top-left), or `:error` when the shape does not fit the
  grid there.
  """
  def covered_slots(%{cols: cols, rows: rows}, anchor)
      when is_integer(anchor) and anchor >= 0 and anchor < @cols * @rows do
    anchor_col = rem(anchor, @cols)
    anchor_row = div(anchor, @cols)

    if anchor_col + cols <= @cols and anchor_row + rows <= @rows do
      slots =
        for row <- 0..(rows - 1), col <- 0..(cols - 1) do
          anchor + row * @cols + col
        end

      {:ok, slots}
    else
      :error
    end
  end

  def covered_slots(_shape, _anchor), do: :error

  @doc "Every slot currently taken by a standing building or an active construction."
  def occupied_slots(%Station{} = station) do
    built = Enum.flat_map(station.buildings, & &1.slots)

    under_construction =
      case station.construction do
        %{kind: :new, slots: slots} -> slots
        _ -> []
      end

    built ++ under_construction
  end

  def get_building(%Station{} = station, building_id),
    do: Enum.find(station.buildings, &(&1.id == building_id))

  def find_building_by_key(%Station{} = station, key),
    do: Enum.find(station.buildings, &(&1.key == key))

  @doc "Begin constructing a NEW building on the given slots."
  def start_new_construction(%Station{} = station, key, faction_id, slots, labor) do
    construction = %{
      building_id: station.next_building_id,
      key: key,
      level: 1,
      faction_id: faction_id,
      slots: slots,
      total_labor: labor,
      remaining_labor: labor,
      kind: :new
    }

    %{station | construction: construction, next_building_id: station.next_building_id + 1}
  end

  @doc "Begin upgrading an existing building to `level`."
  def start_upgrade_construction(%Station{} = station, building, level, labor) do
    construction = %{
      building_id: building.id,
      key: building.key,
      level: level,
      faction_id: building.faction_id,
      slots: building.slots,
      total_labor: labor,
      remaining_labor: labor,
      kind: :upgrade
    }

    %{station | construction: construction}
  end

  @doc """
  Advance the active construction by `labor` production points.
  Returns `{station, nil}` while unfinished (or idle) and
  `{station, completed_building}` on completion.
  """
  def add_labor(%Station{construction: nil} = station, _labor), do: {station, nil}

  def add_labor(%Station{construction: construction} = station, labor) do
    remaining = construction.remaining_labor - labor

    if remaining > 0 do
      {%{station | construction: %{construction | remaining_labor: remaining}}, nil}
    else
      complete(station)
    end
  end

  defp complete(%Station{construction: construction} = station) do
    building =
      case construction.kind do
        :new ->
          %{
            id: construction.building_id,
            key: construction.key,
            level: construction.level,
            faction_id: construction.faction_id,
            slots: construction.slots,
            status: :built
          }

        :upgrade ->
          station
          |> get_building(construction.building_id)
          |> Map.put(:level, construction.level)
      end

    buildings =
      case construction.kind do
        :new -> station.buildings ++ [building]
        :upgrade -> Enum.map(station.buildings, &if(&1.id == building.id, do: building, else: &1))
      end

    {%{station | buildings: buildings, construction: nil}, building}
  end

  @doc "Drop the active construction (government cancel, or lost on capture)."
  def clear_construction(%Station{} = station), do: %{station | construction: nil}

  def remove_building(%Station{} = station, building_id),
    do: %{station | buildings: Enum.reject(station.buildings, &(&1.id == building_id))}

  @doc """
  Re-derive every building's enabled/disabled status against the
  system's current control (`:inhabited_player` + owner faction).
  Returns `{station, changed}` where `changed` lists the buildings
  whose status flipped (for faction-agent notification).
  """
  def sync_statuses(%Station{} = station, status, owner) do
    {buildings, changed} =
      Enum.map_reduce(station.buildings, [], fn building, changed ->
        active? =
          status == :inhabited_player and owner != nil and
            owner.faction_id == building.faction_id

        new_status = if active?, do: :built, else: :disabled

        if new_status == building.status,
          do: {building, changed},
          else: {%{building | status: new_status}, [%{building | status: new_status} | changed]}
      end)

    {%{station | buildings: buildings}, Enum.reverse(changed)}
  end

  @doc """
  Stamp a gateway building with its faction link state (`%{status,
  target_system_id, busy}` or nil) — display/JSON only; the government
  owns the authoritative link records.
  """
  def stamp_link(%Station{} = station, building_id, info) do
    buildings =
      Enum.map(station.buildings, fn building ->
        if building.id == building_id,
          do: Map.put(building, :link, info),
          else: building
      end)

    %{station | buildings: buildings}
  end

  @doc "True when the station holds nothing and builds nothing (client can skip rendering)."
  def empty?(%Station{} = station),
    do: station.buildings == [] and station.construction == nil
end
