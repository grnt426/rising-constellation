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

  @doc """
  Public news feed for the given instance — the last `limit` global
  news rows (no registration, no faction FK) whose key starts with
  `"news."`. Powers the right-rail ticker on /portal/instance/:id and
  the marquee on /portal/play/slow.

  All rows are global by construction (see `Game.News.Server.persist/3`),
  so this is safe to expose to any viewer of the instance page.
  """
  def get_public_news(instance_id, limit \\ 5) do
    from(e in PlayerEvent,
      where:
        e.instance_id == ^instance_id and
          is_nil(e.registration_id) and
          is_nil(e.faction_id) and
          like(e.key, "news.%"),
      order_by: [desc: :inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Cross-instance public news feed — the last `limit` global news rows
  across all *public* instances, tagged with the instance name.
  Powers the scrolling marquee on the /portal/play/:speed game lists.

  Fast instances and tutorials never produce news rows (News.Server's
  eligibility gate), so no speed filter is needed here.
  """
  def get_recent_public_news(limit \\ 5) do
    from(e in PlayerEvent,
      join: i in RC.Instances.Instance,
      on: i.id == e.instance_id,
      where:
        i.public == true and
          is_nil(e.registration_id) and
          is_nil(e.faction_id) and
          like(e.key, "news.%"),
      order_by: [desc: e.inserted_at],
      limit: ^limit,
      select: {e, i.name}
    )
    |> Repo.all()
  end
end
