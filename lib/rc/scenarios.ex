defmodule RC.Scenarios do
  @moduledoc """
  The Scenarios context.
  """
  import Ecto.Query, warn: false

  alias RC.Repo
  alias RC.Scenarios.Scenario
  alias RC.Scenarios.Folder
  alias RC.Scenarios.ScenarioFolder
  alias Ecto.Multi

  @likes_name Application.compile_env(:rc, RC.Scenarios.Folder) |> Keyword.get(:scenario_likes_name)
  @dislikes_name Application.compile_env(:rc, RC.Scenarios.Folder) |> Keyword.get(:scenario_dislikes_name)
  @favorites_name Application.compile_env(:rc, RC.Scenarios.Folder) |> Keyword.get(:scenario_favorites_name)

  # Base query for the public Maps list. Joins folders for the like-style
  # counters, joins author so the view can render a byline without an
  # N+1, and groups by both ids since `author` is a 1:1 we still need
  # to mention in the GROUP BY for Postgres.
  defp list_maps_query() do
    from(m in RC.Scenarios.Map,
      as: :map,
      left_join: f in assoc(m, :folders),
      as: :folders,
      left_join: a in assoc(m, :author),
      as: :author,
      group_by: [m.id, a.id],
      where: m.is_map == true,
      preload: [author: a],
      select_merge: %{
        likes: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, ^@likes_name, f.id),
        dislikes: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, ^@dislikes_name, f.id),
        favorites: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, ^@favorites_name, f.id)
      }
    )
  end

  # Sorting is applied AFTER filters so filter-specific joins don't get in
  # the way. The "most_liked"/"most_favorited" cases re-state the COUNT
  # fragment instead of referring to the SELECT alias — Ecto doesn't know
  # the merged virtual field exists at query-build time, and re-stating is
  # cheaper than a subquery (Postgres folds the duplicated expression).
  defp apply_sort(query, "most_liked") do
    order_by(
      query,
      [folders: f],
      desc: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, ^@likes_name, f.id)
    )
  end

  defp apply_sort(query, "most_favorited") do
    order_by(
      query,
      [folders: f],
      desc: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, ^@favorites_name, f.id)
    )
  end

  defp apply_sort(query, _newest_or_unknown) do
    # Default — newest first. Without an explicit order Repo.paginate
    # returns rows in undefined order, which makes page 2 wobble across
    # reloads.
    order_by(query, [map: m], desc: m.inserted_at)
  end

  # Adds the default "only published" filter — community designs are drafts
  # until the author hits Publish. Existing seeded rows were back-filled to
  # inserted_at by the Stage 2 migration so they remain visible.
  defp where_published(query) do
    where(query, [m], not is_nil(m.published_at))
  end

  # The default public-list visibility rule: every published row, plus the
  # caller's own drafts (so a freshly-created map doesn't vanish from the
  # author's view before they hit Publish). Callers pass nil when they're
  # not logged in (publicly cached responses); we still honor that, just
  # without the own-drafts side of the OR.
  defp where_visible_to(query, nil), do: where_published(query)

  defp where_visible_to(query, account_id) when is_integer(account_id) do
    where(
      query,
      [m],
      not is_nil(m.published_at) or m.author_id == ^account_id
    )
  end

  @doc """
  Returns the list of maps.

  ## Examples

      iex> list_maps()
      [%RC.Scenarios.Map{}, ...]

  """
  def list_maps do
    list_maps_query()
    |> where_published()
    |> apply_sort("newest")
    |> Repo.paginate()
  end

  @doc """
  Maps visible to `account_id` — every published row, plus that account's
  own drafts. Used by the Forge list page so an author can see (and
  re-open) a freshly-created draft they haven't yet published.
  """
  def list_maps_visible_to(account_id) do
    list_maps_query()
    |> where_visible_to(account_id)
    |> apply_sort("newest")
    |> Repo.paginate()
  end

  @doc """
  Returns the list of maps with filtered fields.
  Filters should be provided with a map structure.

  ## Examples

      iex> list_maps(filters)
      [%RC.Scenarios.Map{}, ...]

  """
  def list_maps(filters) when is_map(filters) do
    # Two opt-in filter modes:
    #   "drafts" => account_id   — only that author's drafts
    #   "visible_to" => account_id — published + that account's own drafts
    # Otherwise the default "published-only" gate applies (e.g. unauth or
    # admin viewing the all-community gallery).
    base_query =
      cond do
        is_integer(Map.get(filters, "drafts")) ->
          list_maps_query()
          |> where([m], is_nil(m.published_at) and m.author_id == ^Map.get(filters, "drafts"))

        is_integer(Map.get(filters, "visible_to")) ->
          list_maps_query()
          |> where_visible_to(Map.get(filters, "visible_to"))

        true ->
          list_maps_query() |> where_published()
      end

    base_query
    |> put_map_filters(Map.drop(filters, ["drafts", "visible_to"]))
    |> Repo.paginate()
  end

  @doc """
  Lists every map owned by `account_id`, drafts and published alike.
  Used by the "My maps" tab in the Forge.
  """
  def list_maps_by_author(account_id) when is_integer(account_id) do
    list_maps_query()
    |> where([m], m.author_id == ^account_id)
    |> apply_sort("newest")
    |> Repo.paginate()
  end

  @doc """
  Gets a single map.

  Returns `nil` if the RC.Scenarios.Map does not exist.

  ## Examples

      iex> get_map(123)
      %RC.Scenarios.Map{}

      iex> get_map!(456)
      nil

  """
  def get_map(id) do
    Repo.one(
      from(m in RC.Scenarios.Map,
        left_join: f in assoc(m, :folders),
        left_join: a in assoc(m, :author),
        group_by: [m.id, a.id],
        where: m.id == ^id and m.is_map == true,
        preload: [author: a],
        select_merge: %{
          likes: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, @likes_name, f.id),
          dislikes: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, @dislikes_name, f.id),
          favorites: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, @favorites_name, f.id)
        }
      )
    )
  end

  @doc """
  Gets a single map as a Scenario structure.
  This function is used to delete a map since Scenario and Map shares the same table.

  Returns `nil` if the RC.Scenarios.Map does not exist.

  ## Examples

      iex> get_map(123)
      %RC.Scenarios.Map{}

      iex> get_map!(456)
      nil

  """
  def get_map_as_scenario(id) do
    Repo.one(
      from(s in Scenario,
        where: s.id == ^id and s.is_map == true
      )
    )
  end

  @doc """
  Creates a map.

  ## Examples

      iex> create_map(%{field: value})
      {:ok, %RC.Scenarios.Map{}}

      iex> create_map(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_map(attrs, author_id) when is_integer(author_id) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :map,
      %RC.Scenarios.Map{}
      |> RC.Scenarios.Map.changeset(attrs)
      |> RC.Scenarios.Map.put_author(author_id)
    )
    |> Ecto.Multi.update(:map_with_thumbnail, &RC.Scenarios.Map.thumbnail_changeset(&1.map, attrs))
    |> Repo.transaction()
  end

  # Anonymous / engine path — used by seeds.exs and the test suite. Author
  # stays NULL so the row renders as "Official", matching pre-Stage-2
  # behavior for engine-seeded maps.
  def create_map(attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:map, RC.Scenarios.Map.changeset(%RC.Scenarios.Map{}, attrs))
    |> Ecto.Multi.update(:map_with_thumbnail, &RC.Scenarios.Map.thumbnail_changeset(&1.map, attrs))
    |> Repo.transaction()
  end

  @doc """
  Creates a map.

  ## Examples

      iex> create_map(%{field: value})
      {:ok, %RC.Scenarios.Map{}}

      iex> create_map(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_map(attrs, author_id, :no_thumbnail) when is_integer(author_id) do
    %RC.Scenarios.Map{}
    |> RC.Scenarios.Map.changeset_no_thumbnail(attrs)
    |> RC.Scenarios.Map.put_author(author_id)
    |> Repo.insert()
  end

  # Anonymous variant — see create_map/1.
  def create_map(attrs, :no_thumbnail) do
    %RC.Scenarios.Map{}
    |> RC.Scenarios.Map.changeset_no_thumbnail(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a map.

  ## Examples

      iex> update_map(map, %{field: new_value})
      {:ok, %RC.Scenarios.Map{}}

      iex> update_map(map, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_map(%RC.Scenarios.Map{} = map, attrs) do
    map
    |> RC.Scenarios.Map.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Sets `published_at` on a map. Idempotent — re-publishing a published map
  refreshes the timestamp (which is fine and rare).
  """
  def publish_map(%RC.Scenarios.Map{} = map) do
    map
    |> RC.Scenarios.Map.publish_changeset()
    |> Repo.update()
  end

  @doc """
  Attaches a thumbnail upload to a map. `attrs` should contain
  `%{thumbnail: %Plug.Upload{}}`. Pipes through the Waffle changeset
  which runs `convert -resize x400` (or whatever transform ThumbnailFile
  declares) on save.
  """
  def update_map_thumbnail(%RC.Scenarios.Map{} = map, attrs) do
    map
    |> RC.Scenarios.Map.thumbnail_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  True when `account_id` is the author of map `map_id`. Used by
  Portal.Plug.Authorization to gate per-map mutations (PUT/DELETE
  /api/maps/:mid). Maps with no author (engine-seeded "Official" rows) are
  *never* author-owned by a community account; only admins can touch them.
  """
  def own_map?(account_id, map_id) do
    Repo.exists?(
      from(m in RC.Scenarios.Map,
        where: m.id == ^map_id and m.is_map == true and m.author_id == ^account_id
      )
    )
  end

  # See `list_maps_query/0`. Identical shape — author preloaded for the
  # byline, group_by includes the author id so Postgres accepts the select.
  defp list_scenarios_query() do
    from(s in RC.Scenarios.Scenario,
      as: :scenario,
      left_join: f in assoc(s, :folders),
      as: :folders,
      left_join: a in assoc(s, :author),
      as: :author,
      group_by: [s.id, a.id],
      where: s.is_map == false,
      preload: [author: a],
      select_merge: %{
        likes: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, ^@likes_name, f.id),
        dislikes: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, ^@dislikes_name, f.id),
        favorites: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, ^@favorites_name, f.id)
      }
    )
  end

  # Same shape as `apply_sort/2` above but targeting the scenarios named
  # binding (`:scenario` vs `:map`).
  defp apply_scenario_sort(query, "most_liked") do
    order_by(
      query,
      [folders: f],
      desc: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, ^@likes_name, f.id)
    )
  end

  defp apply_scenario_sort(query, "most_favorited") do
    order_by(
      query,
      [folders: f],
      desc: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, ^@favorites_name, f.id)
    )
  end

  defp apply_scenario_sort(query, _newest_or_unknown) do
    order_by(query, [scenario: s], desc: s.inserted_at)
  end

  @doc """
  Returns the list of scenarios.

  ## Examples

      iex> list_scenarios()
      [%Scenario{}, ...]

  """

  def list_scenarios do
    list_scenarios_query()
    |> where([s], not is_nil(s.published_at))
    |> apply_scenario_sort("newest")
    |> Repo.paginate()
  end

  @doc """
  Scenarios visible to `account_id` — see `list_maps_visible_to/1`.
  """
  def list_scenarios_visible_to(account_id) do
    base = list_scenarios_query()

    query =
      case account_id do
        nil ->
          where(base, [s], not is_nil(s.published_at))

        id when is_integer(id) ->
          where(base, [s], not is_nil(s.published_at) or s.author_id == ^id)
      end

    query
    |> apply_scenario_sort("newest")
    |> Repo.paginate()
  end

  @doc """
  Returns the filtered list of scenarios.
  The filters should be provided in a map structure.

  ## Examples

      iex> list_scenarios()
      [%Scenario{}, ...]

  """
  def list_scenarios(filters) when is_map(filters) do
    # Mirrors list_maps/1 — see that docstring for the filter modes.
    base_query =
      cond do
        is_integer(Map.get(filters, "drafts")) ->
          list_scenarios_query()
          |> where([s], is_nil(s.published_at) and s.author_id == ^Map.get(filters, "drafts"))

        is_integer(Map.get(filters, "visible_to")) ->
          aid = Map.get(filters, "visible_to")

          list_scenarios_query()
          |> where([s], not is_nil(s.published_at) or s.author_id == ^aid)

        true ->
          list_scenarios_query()
          |> where([s], not is_nil(s.published_at))
      end

    base_query
    |> put_scenario_filters(Map.drop(filters, ["drafts", "visible_to"]))
    |> Repo.paginate()
  end

  @doc """
  Lists every scenario owned by `account_id`, drafts and published alike.
  """
  def list_scenarios_by_author(account_id) when is_integer(account_id) do
    list_scenarios_query()
    |> where([s], s.author_id == ^account_id)
    |> apply_scenario_sort("newest")
    |> Repo.paginate()
  end

  @doc """
  List scenario in reserved folder.
  `folder_atom` is either `:scenario_likes_name`, `scenario_dislikes_name` or `scenario_favorites_name`


  ## Examples

      iex> list_scenarios(1, :scenario_likes_name)
      [%Scenario{}, ...]

  """
  def list_scenarios(account_id, folder_atom) do
    folder_name = Application.get_env(:rc, RC.Scenarios.Folder) |> Keyword.get(folder_atom)

    Repo.paginate(
      from(s in Scenario,
        join: f in assoc(s, :folders),
        where: f.name == ^folder_name and f.account_id == ^account_id
      )
    )
  end

  @doc """
  Gets a single scenario.

  Returns nil` if the scenario does not exist.

  ## Examples

      iex> get_scenario(123)
      %scenario{}

      iex> get_scenario!(456)
      nil

  """
  def get_scenario(id) do
    Repo.one(
      from(s in Scenario,
        left_join: f in assoc(s, :folders),
        left_join: a in assoc(s, :author),
        group_by: [s.id, a.id],
        where: s.id == ^id and s.is_map == false,
        preload: [author: a],
        select_merge: %{
          likes: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, @likes_name, f.id),
          dislikes: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, @dislikes_name, f.id),
          favorites: fragment("COUNT(CASE WHEN ? = ? THEN ? ELSE NULL END)", f.name, @favorites_name, f.id)
        }
      )
    )
  end

  @doc """
  Creates a scenario with either:
  - a thumbnail to upload
  - using an already uploaded image as thumbail
  - no thumbnail

  ## Examples

      iex> create_scenario(%{field: value, thumbnail: %Plug.Upload{...}}, :create_thumbnail)
      {:ok, %Scenario{}}

      iex> create_scenario(%{field: bad_value}, :create_thumbnail)
      {:error, %Ecto.Changeset{}}

      iex> create_scenario(%{field: value}, :reuse_thumbnail)
      {:ok, %Scenario{}}

      iex> create_scenario(%{field: bad_value}, :reuse_thumbnail)
      {:error, %Ecto.Changeset{}}

      iex> create_scenario(%{field: value}, :no_thumbnail)
      {:ok, %Scenario{}}

      iex> create_scenario(%{field: bad_value}, :no_thumbnail)
      {:error, %Ecto.Changeset{}}
  """
  def create_scenario(scenario_attrs, author_id, :create_thumbnail) when is_integer(author_id) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :scenario,
      %Scenario{}
      |> Scenario.changeset(scenario_attrs)
      |> Scenario.put_author(author_id)
    )
    |> Ecto.Multi.update(
      :scenario_with_thumbnail,
      &Scenario.thumbnail_changeset(&1.scenario, scenario_attrs)
    )
    |> Repo.transaction()
  end

  def create_scenario(scenario_attrs, author_id, :reuse_thumbnail) when is_integer(author_id) do
    %Scenario{}
    |> Scenario.changeset_reuse_thumbnail(scenario_attrs)
    |> Scenario.put_author(author_id)
    |> Repo.insert()
  end

  def create_scenario(scenario_attrs, author_id, :no_thumbnail) when is_integer(author_id) do
    %Scenario{}
    |> Scenario.changeset_no_thumbnail(scenario_attrs)
    |> Scenario.put_author(author_id)
    |> Repo.insert()
  end

  # Anonymous variants — see create_map/1 for the rationale. Tests and
  # fixtures call these without an author; the row renders as Official.
  def create_scenario(scenario_attrs, :create_thumbnail) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:scenario, Scenario.changeset(%Scenario{}, scenario_attrs))
    |> Ecto.Multi.update(
      :scenario_with_thumbnail,
      &Scenario.thumbnail_changeset(&1.scenario, scenario_attrs)
    )
    |> Repo.transaction()
  end

  def create_scenario(scenario_attrs, :reuse_thumbnail) do
    %Scenario{}
    |> Scenario.changeset_reuse_thumbnail(scenario_attrs)
    |> Repo.insert()
  end

  def create_scenario(scenario_attrs, :no_thumbnail) do
    %Scenario{}
    |> Scenario.changeset_no_thumbnail(scenario_attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a scenario.

  ## Examples

      iex> update_scenario(scenario, %{field: new_value})
      {:ok, %scenario{}}

      iex> update_scenario(scenario, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_scenario(%Scenario{} = scenario, attrs) do
    scenario
    |> Scenario.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Sets `published_at` on a scenario. See `publish_map/1`.
  """
  def publish_scenario(%Scenario{} = scenario) do
    scenario
    |> Scenario.publish_changeset()
    |> Repo.update()
  end

  @doc """
  Attaches a thumbnail upload to a scenario. See `update_map_thumbnail/2`.
  """
  def update_scenario_thumbnail(%Scenario{} = scenario, attrs) do
    scenario
    |> Scenario.thumbnail_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  True when `account_id` is the author of scenario `scenario_id`. Used by
  Portal.Plug.Authorization to gate per-scenario mutations. Anonymous
  rows (no author) are admin-only — same rule as own_map?/2.
  """
  def own_scenario?(account_id, scenario_id) do
    Repo.exists?(
      from(s in Scenario,
        where: s.id == ^scenario_id and s.is_map == false and s.author_id == ^account_id
      )
    )
  end

  @doc """
  Deletes a scenario.

  ## Examples

      iex> delete_scenario(scenario)
      {:ok, %Scenario{}}

      iex> delete_scenario(scenario)
      {:error, %Ecto.Changeset{}}

  """
  def delete_scenario(%Scenario{} = scenario) do
    Repo.delete(scenario)
  end

  @doc """
  Returns the count of Map and Scenario in a special folder.
  The parameter `folder_atom` should be either `:scenario_likes_name`, `scenario_dislikes_name` or `scenario_favorites_name`.
  """
  def get_reserved_folder_count(scenario_id, folder_atom) do
    reserved_name = Application.get_env(:rc, RC.Scenarios.Folder) |> Keyword.get(folder_atom)

    query =
      from(sf in ScenarioFolder,
        join: f in Folder,
        on: sf.folder_id == f.id,
        where: sf.scenario_id == ^scenario_id and f.name == ^reserved_name
      )

    Repo.aggregate(query, :count)
  end

  @doc """
  Returns `true` if a special folder exists.
  The parameter `folder_atom` should be either `:scenario_likes_name`, `scenario_dislikes_name` or `scenario_favorites_name`.
  """
  def folder_exists?(account_id, folder_atom) do
    folder_name = Application.get_env(:rc, RC.Scenarios.Folder) |> Keyword.get(folder_atom)

    Repo.exists?(
      from(f in Folder,
        where: f.name == ^folder_name and f.account_id == ^account_id
      )
    )
  end

  @doc """
  Returns the list of folders.

  ## Examples

      iex> list_folders()
      [%Folder{}, ...]

  """
  def list_folders do
    Repo.paginate(Folder)
  end

  @doc """
  Gets a single folder.

  Raises `Ecto.NoResultsError` if the Folder does not exist.

  ## Examples

      iex> get_folder(123)
      %Folder{}

      iex> get_folder(456)
      ** (Ecto.NoResultsError)

  """
  def get_folder(id), do: Repo.get(Folder, id)

  @doc """
  Returns true if `folder_id` belongs to `account_id`. Used by the
  Portal.Plug.Authorization `:fid` clause to gate per-folder mutation
  routes (PUT/DELETE /scenarios/:sid/folders/:fid and similar) — folders
  include the system-reserved like/dislike/favorite collections, so an
  unscoped check would let users tamper with anyone else's vote tallies.
  """
  def own_folder?(account_id, folder_id) do
    Repo.exists?(
      from(f in Folder,
        where: f.account_id == ^account_id and f.id == ^folder_id
      )
    )
  end

  @doc """
  Gets a single reserved folder given an account_id.
  The parameter `folder_atom` should be either `:scenario_likes_name`, `scenario_dislikes_name` or `scenario_favorites_name`.

  Returns `nil` if the folder does not exist.
  """
  def get_folder(account_id, folder_atom) do
    folder_name = Application.get_env(:rc, RC.Scenarios.Folder) |> Keyword.get(folder_atom)

    Repo.one(
      from(f in Folder,
        where: f.name == ^folder_name and f.account_id == ^account_id
      )
    )
  end

  @doc """
  Gets a like or dislike folder.
  If the atom is `:like` it looks for the `:dislike` folder and vice versa.
  Returns `nil` if the folders does not exist.


  ## Examples

      iex> get_opposite_folder(account_id, :like)
      {:ok, %Folder{}}

      iex> get_opposite_folder(account_id, :like)
      nil

  """
  def get_opposite_folder(account_id, scenario_id, folder_atom) do
    folder_name =
      if folder_atom == :like,
        do: @dislikes_name,
        else: @likes_name

    Repo.one(
      from(f in Folder,
        join: s in assoc(f, :scenarios),
        where: f.account_id == ^account_id and f.name == ^folder_name and s.id == ^scenario_id
      )
    )
  end

  @doc """
  Creates a folder.

  ## Examples

      iex> create_folder(%{field: value})
      {:ok, %Folder{}}

      iex> create_folder(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_folder(attrs) do
    %Folder{}
    |> Folder.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a folder with an account reference.

  ## Examples

      iex> create_folder(%{field: value}, 123)
      {:ok, %Folder{}}

  """
  def create_folder(attrs, account_id) do
    %Folder{}
    |> Map.put(:account_id, account_id)
    |> Folder.changeset_not_reserved(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a reserved folder with an account reference.
  The parameter `folder_atom` should be either `:scenario_likes_name`, `scenario_dislikes_name` or `scenario_favorites_name`.

  """
  def create_reserved_folder(attrs, account_id) do
    %Folder{}
    |> Map.put(:account_id, account_id)
    |> Folder.changeset_reserved(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a folder.

  ## Examples

      iex> update_folder(folder, %{field: new_value})
      {:ok, %Folder{}}

      iex> update_folder(folder, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_folder(%Folder{} = folder, attrs) do
    folder
    |> Folder.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a folder.

  ## Examples

      iex> delete_folder(folder)
      {:ok, %Folder{}}

      iex> delete_folder(folder)
      {:error, %Ecto.Changeset{}}

  """
  def delete_folder(%Folder{} = folder) do
    Repo.delete(folder)
  end

  @doc """
  Inserts a Map or Scenario in a Folder, `scenario_ids` is a list of ids.
  Map and Scenario shares the same table so the two structures can be inserted at the same time.
  """
  def insert_map_or_scenario(folder, scenario_ids) do
    # `on_conflict: :nothing` makes the insert idempotent — clicking
    # "like" twice on the same scenario is a no-op instead of a 500.
    # The composite PK (folder_id, scenario_id) handles the conflict
    # detection; we don't need an explicit `conflict_target`.
    {trx, _} =
      Enum.reduce(scenario_ids, {Multi.new(), 0}, fn sid, {trx_acc, idx_acc} ->
        folder_params = %{folder_id: folder.id, scenario_id: sid}

        {trx_acc
         |> Multi.insert(
           "scenario_folders_#{idx_acc}",
           ScenarioFolder.changeset(%ScenarioFolder{}, folder_params),
           on_conflict: :nothing
         ), idx_acc + 1}
      end)

    Repo.transaction(trx)
  end

  @doc """
  Removes a Map or Scenario from a Folder.
  """
  def remove_map_or_scenario(folder, scenario_id) do
    Repo.delete_all(
      from(sf in ScenarioFolder,
        where: sf.scenario_id == ^scenario_id and sf.folder_id == ^folder.id
      )
    )
  end

  # Converts the entries in `filters` into where/order clauses. Unknown
  # keys are silently ignored — this is reached from controller params,
  # which include junk like `page`, `visible_to`, etc.
  defp put_map_filters(query, filters) when is_map(filters) do
    Enum.reduce(filters, query, fn {key, val}, query_acc ->
      case key do
        "id" ->
          where(query_acc, [map: m], m.id == ^val)

        "is_official" ->
          where(query_acc, [map: m], m.is_official == ^val)

        "size" ->
          where(query_acc, fragment("game_metadata @> ?", ^%{size: String.to_integer(val)}))

        "name" ->
          pattern = "%" <> val <> "%"
          where(query_acc, [map: m], fragment("game_metadata->>'name' like ?", ^pattern))

        # Author byline search — case-insensitive substring on accounts.name
        # via the existing :author named join.
        "author" ->
          pattern = "%" <> val <> "%"
          where(query_acc, [author: a], ilike(a.name, ^pattern))

        # Chip filters. Each takes an integer account_id from the caller;
        # the controller injects current_user when the chip is on.
        #   "officials" → engine-seeded rows (no author + is_official).
        #     The value is unused; the chip is a toggle.
        #   "mine"      → only rows the caller authored.
        #   "favorited" → rows the caller has in their favorites folder.
        "officials" ->
          where(query_acc, [map: m], is_nil(m.author_id) and m.is_official == true)

        "mine" ->
          where(query_acc, [map: m], m.author_id == ^to_int(val))

        "favorited" ->
          where(
            query_acc,
            [map: m],
            m.id in subquery(favorited_ids_query(to_int(val)))
          )

        "sort" ->
          apply_sort(query_acc, val)

        _ ->
          query_acc
      end
    end)
    # Always apply a sort. If no `sort` filter was passed, the no-op
    # clause above didn't fire, so we tack on the default here.
    |> ensure_sorted(filters, :map)
  end

  # See `put_map_filters/2` for the scope rationale on each clause; this
  # mirror keeps the scenarios-only filters (speed, factions, mode) in
  # one place and reuses the shared chip filters.
  defp put_scenario_filters(query, filters) when is_map(filters) do
    Enum.reduce(filters, query, fn {key, val}, query_acc ->
      case key do
        "id" ->
          where(query_acc, [scenario: s], s.id == ^val)

        "is_official" ->
          where(query_acc, [scenario: s], s.is_official == ^val)

        "size" ->
          where(query_acc, fragment("game_metadata @> ?", ^%{size: String.to_integer(val)}))

        "speed" ->
          where(query_acc, fragment("game_metadata @> ?", ^%{speed: val}))

        "mode" ->
          where(query_acc, fragment("game_metadata @> ?", ^%{mode: val}))

        "name" ->
          pattern = "%" <> val <> "%"
          where(query_acc, [scenario: s], fragment("game_metadata->>'name' like ?", ^pattern))

        "author" ->
          pattern = "%" <> val <> "%"
          where(query_acc, [author: a], ilike(a.name, ^pattern))

        # game_metadata.factions is a jsonb array of {key, sector_number}
        # tuples; `jsonb_array_length` gives the count without unpacking it.
        "factions" ->
          where(
            query_acc,
            fragment("jsonb_array_length(game_metadata->'factions') = ?", ^to_int(val))
          )

        "officials" ->
          where(query_acc, [scenario: s], is_nil(s.author_id) and s.is_official == true)

        "mine" ->
          where(query_acc, [scenario: s], s.author_id == ^to_int(val))

        "favorited" ->
          where(
            query_acc,
            [scenario: s],
            s.id in subquery(favorited_ids_query(to_int(val)))
          )

        "sort" ->
          apply_scenario_sort(query_acc, val)

        _ ->
          query_acc
      end
    end)
    |> ensure_sorted(filters, :scenario)
  end

  # Subquery used by the "favorited" chip on both maps and scenarios:
  # the set of scenario_ids (maps and scenarios share the table) that
  # `account_id` has placed in their favorites folder.
  defp favorited_ids_query(account_id) do
    from sf in ScenarioFolder,
      join: folder in Folder,
      on: sf.folder_id == folder.id,
      where: folder.account_id == ^account_id and folder.name == ^@favorites_name,
      select: sf.scenario_id
  end

  # Sort is applied last so it composes with all the where-clause filters
  # above. If the caller passed a `sort` key it already ran during reduce
  # — but the reduce traversal order isn't guaranteed, so re-applying it
  # here guarantees the final order. With no `sort` key, this is the
  # only call that sets one.
  defp ensure_sorted(query, filters, :map) do
    apply_sort(query, Map.get(filters, "sort", "newest"))
  end

  defp ensure_sorted(query, filters, :scenario) do
    apply_scenario_sort(query, Map.get(filters, "sort", "newest"))
  end

  # Filter values arrive as strings from the controller (URL params),
  # but for "mine"/"favorited" we need an integer account_id. Accept
  # both, return 0 on garbage (which will never match a real account).
  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp to_int(_), do: 0
end
