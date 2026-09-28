defmodule RC.LegacyLobby do
  @moduledoc """
  Official-match extras for the Legacy lobby page (/play/slow):

    * the latest official result card (official = `instances.discord_ready`),
    * whether an official match is currently open or running,
    * the admin-announced start of the next official match.
  """

  import Ecto.Query, warn: false

  alias RC.Instances.{Faction, Instance}
  alias RC.Repo
  alias RC.SiteSettings

  @active_states ~w(open running paused not_running maintenance)
  @next_official_key "next_official_legacy"

  @doc """
  The most recent official match that has a declared victory or has ended,
  or nil. Factions come in final-rank order with their end-of-game VP;
  `archive_id` follows RC.Archive visibility (unpublished for admins only).
  """
  def latest_official_result(include_unpublished_archives? \\ false) do
    factions = from(f in Faction, order_by: [asc_nulls_last: f.final_rank, asc: f.id])

    from(i in Instance,
      left_join: v in assoc(i, :victory),
      where: i.discord_ready and not i.is_bot_only and (not is_nil(v.id) or i.state == "ended"),
      order_by: [desc: fragment("coalesce(?, ?)", v.inserted_at, i.updated_at), desc: i.id],
      limit: 1,
      preload: [factions: ^factions],
      select: {i, v}
    )
    |> Repo.one()
    |> case do
      nil -> nil
      {instance, victory} -> result(instance, victory, include_unpublished_archives?)
    end
  end

  defp result(instance, victory, include_unpublished_archives?) do
    winner = victory && Enum.find(instance.factions, &(&1.final_rank == 1))
    archives = RC.Archive.match_ids_by_instance([instance.id], include_unpublished_archives?)

    %{
      instance_id: instance.id,
      name: instance.name,
      map_name: (instance.game_metadata || %{})["name"] || instance.name,
      victory_type: victory && victory.victory_type,
      ended_at: if(victory, do: victory.inserted_at, else: instance.updated_at),
      winner_faction: winner && winner.faction_ref,
      factions:
        Enum.map(instance.factions, fn f ->
          %{key: f.faction_ref, rank: f.final_rank, victory_points: f.final_victory_points}
        end),
      archive_id: archives[instance.id]
    }
  end

  @doc """
  Is an official match open for registration or in progress? A match whose
  victory is already declared doesn't count, even during its post-victory
  tail (the instance stays "running" for a few hours after the win).
  """
  def official_active? do
    from(i in Instance,
      left_join: v in assoc(i, :victory),
      where: i.discord_ready and not i.is_bot_only and i.state in ^@active_states and is_nil(v.id)
    )
    |> Repo.exists?()
  end

  @doc """
  The announced next official start: `%{"date" => "YYYY-MM-DD", "starts_at"
  => ISO-8601 UTC | nil}`, or nil when none is set. The date is always set;
  the time is optional so a day can be announced before the hour is known.
  """
  def next_official, do: SiteSettings.get(@next_official_key)

  @doc """
  Sets or clears (blank date) the announced next official start. `starts_at`
  is the full instant when a time was chosen; `date` is the day as the admin
  picked it, shown as-is when there is no time.
  """
  def put_next_official(params) do
    case {blank(params["date"]), blank(params["starts_at"])} do
      {nil, nil} ->
        SiteSettings.delete(@next_official_key)
        {:ok, nil}

      {nil, _} ->
        {:error, :date_required}

      {date, starts_at} ->
        with {:ok, date} <- parse_date(date),
             {:ok, starts_at} <- parse_starts_at(starts_at) do
          value = %{"date" => Date.to_iso8601(date), "starts_at" => starts_at}
          {:ok, _} = SiteSettings.put(@next_official_key, value)
          {:ok, value}
        end
    end
  end

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank(_), do: nil

  defp parse_date(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date}
    end
  end

  defp parse_starts_at(nil), do: {:ok, nil}

  defp parse_starts_at(starts_at) do
    case DateTime.from_iso8601(starts_at) do
      {:ok, dt, _offset} -> {:ok, dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
      _ -> {:error, :invalid_starts_at}
    end
  end
end
