defmodule RC.Archive.Json do
  @moduledoc """
  jsonb column that may hold a list as well as a map. Ecto's `:map` refuses
  lists and `{:array, _}` means a Postgres array, so archive columns that
  store JSON arrays use this pass-through type instead.
  """
  use Ecto.Type

  def type, do: :map

  def cast(value) when is_map(value) or is_list(value), do: {:ok, value}
  def cast(_), do: :error

  def load(value), do: {:ok, value}

  def dump(value) when is_map(value) or is_list(value), do: {:ok, value}
  def dump(_), do: :error
end
