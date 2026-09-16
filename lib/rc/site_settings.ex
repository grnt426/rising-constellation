defmodule RC.SiteSettings do
  @moduledoc """
  Admin-editable site-wide settings: one jsonb value per string key.

  Keys in use:

    * `"next_official_legacy"` — `%{"date" => "YYYY-MM-DD", "starts_at" =>
      ISO-8601 UTC | nil}`, see `RC.LegacyLobby`.
  """

  import Ecto.Query, warn: false

  alias RC.Repo

  defmodule Setting do
    use Ecto.Schema

    @primary_key {:key, :string, autogenerate: false}
    schema "site_settings" do
      field(:value, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end
  end

  def get(key) do
    case Repo.get(Setting, key) do
      nil -> nil
      setting -> setting.value
    end
  end

  def put(key, value) when is_map(value) do
    now = DateTime.utc_now()

    Repo.insert(%Setting{key: key, value: value, inserted_at: now, updated_at: now},
      on_conflict: [set: [value: value, updated_at: now]],
      conflict_target: :key
    )
  end

  def delete(key) do
    from(s in Setting, where: s.key == ^key) |> Repo.delete_all()
    :ok
  end
end
