defmodule RC.PlayerEvents do
  import Ecto.Query, warn: false

  alias RC.Repo
  alias RC.Instances.PlayerEvent

  def create(attrs \\ %{}) do
    %PlayerEvent{}
    |> PlayerEvent.changeset(attrs)
    |> Repo.insert()
  end

  def get_for_player(assigns, params \\ %{}) do
    from(e in PlayerEvent,
      where:
        e.instance_id == ^assigns.instance_id and
          (e.registration_id == ^assigns.registration_id or
             e.faction_id == ^assigns.faction_id or
             (is_nil(e.faction_id) and is_nil(e.registration_id))),
      order_by: [desc: :inserted_at]
    )
    |> RC.Repo.paginate(params)
  end

  # Personal report feed for the in-game Reports panel — only the player's
  # OWN agent-action reports: registration-scoped + type "box" (the outcome
  # summary cards for raid/infiltration/conversion/fight/etc.). Excluded:
  #   * shared faction/global rows — their rows are shared, so the per-player
  #     read-state / deletion below can't apply to them;
  #   * transient "text" pings (started/cancelled/discovered) — they stay in
  #     the calendar EventPanel (get_for_player/2), which shows everything.
  # All read/delete helpers use the SAME scope (report_query/1) so the Reports
  # panel and its bulk actions operate on exactly the set the player sees.
  def get_for_registration(registration_id, params \\ %{}) do
    report_query(registration_id)
    |> order_by(desc: :inserted_at)
    |> RC.Repo.paginate(params)
  end

  def mark_read(registration_id, event_id) do
    report_query(registration_id)
    |> where([e], e.id == ^event_id)
    |> Repo.update_all(set: [is_read: true])
  end

  def mark_all_read(registration_id) do
    report_query(registration_id)
    |> where([e], e.is_read == false)
    |> Repo.update_all(set: [is_read: true])
  end

  def delete_read(registration_id) do
    report_query(registration_id)
    |> where([e], e.is_read == true)
    |> Repo.delete_all()
  end

  def delete_all(registration_id) do
    report_query(registration_id)
    |> Repo.delete_all()
  end

  # Scopes every Reports-panel query to one player's own box-type events so a
  # player can never touch a shared faction/global row or another player's data.
  defp report_query(registration_id) do
    from(e in PlayerEvent, where: e.registration_id == ^registration_id and e.type == "box")
  end
end
