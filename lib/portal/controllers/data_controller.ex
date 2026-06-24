defmodule Portal.DataController do
  use Portal, :controller

  action_fallback(Portal.FallbackController)

  def all_in_module(conn, %{"module" => module}) do
    metadata = [
      speed: :fast,
      mode: :prod
    ]

    case Data.Querier.string_to_module(module) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{message: :data_not_found})

      module ->
        values = Data.Querier.fetch_all(module, metadata) |> filter_selectable(module)
        json(conn, values)
    end
  end

  def all(conn, _params) do
    metadata = [
      speed: :fast,
      mode: :prod
    ]

    values =
      Data.Querier.modules()
      |> Enum.filter(fn m -> m.export end)
      |> Enum.reduce(%{}, fn m, acc ->
        Map.put(acc, m.string, Data.Querier.fetch_all(m.module, metadata) |> filter_selectable(m.module))
      end)

    json(conn, values)
  end

  # The :daily speed (Legacy content at a fast clock) powers the daily
  # challenge but must never be offered as a scenario option, so strip any
  # speed flagged `selectable: false` from the editor-facing data payload.
  # Other modules pass through untouched.
  defp filter_selectable(values, Data.Game.Speed) when is_list(values),
    do: Enum.filter(values, & &1.selectable)

  defp filter_selectable(values, _module), do: values

  # def one(conn, %{"module" => module, "key" => key}) do
  #   case Data.Querier.string_to_module(module) do
  #     nil ->
  #       conn
  #       |> put_status(404)
  #       |> json(%{message: :data_not_found})

  #     module ->
  #       value = Data.Querier.fetch_one(module, [], key)
  #       json(conn, value)
  #   end
  # end

  # Forge mutator catalog — used by the Scenario editor's mutator
  # picker. Returns the static list defined in Data.Game.Mutator;
  # not speed/mode-keyed like the per-instance content data so it
  # bypasses Data.Querier entirely.
  def mutators(conn, _params) do
    catalog =
      Data.Game.Mutator.catalog()
      |> Enum.map(fn m ->
        %{
          key: Atom.to_string(m.key),
          name: m.name,
          description: m.description,
          implemented: m.implemented
        }
      end)

    json(conn, catalog)
  end

  def random_name(conn, %{"module" => module, "size" => size}) do
    {size, _} = Integer.parse(size)

    case Data.Picker.name_to_file(module) do
      :file_not_found ->
        conn
        |> put_status(404)
        |> json(%{message: :data_not_found})

      _ ->
        values = Data.Picker.random_unsafe(module, size)
        json(conn, values)
    end
  end
end
