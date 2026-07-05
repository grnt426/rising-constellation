defmodule Data.Picker do
  def index() do
    [
      %{name: "place", file_path: "place.txt"},
      %{name: "sector", file_path: "sector.txt"},
      %{name: "ship", file_path: "ship.txt"},
      %{name: "male-firstname", file_path: "firstname/male.txt"},
      %{name: "female-firstname", file_path: "firstname/female.txt"},
      %{name: "tetrarchic-foundation", file_path: "foundation/tetrarchic.txt"},
      %{name: "myrmeziriannic-foundation", file_path: "foundation/myrmeziriannic.txt"},
      %{name: "cardanic-foundation", file_path: "foundation/cardanic.txt"},
      %{name: "syn-foundation", file_path: "foundation/syn.txt"},
      %{name: "stelloliberalism-foundation", file_path: "foundation/stelloliberalism.txt"}
    ]
  end

  def name_to_file(key) do
    case Enum.find(index(), fn f -> f.name == key end) do
      nil -> :file_not_found
      result -> result.file_path
    end
  end

  def random(name, instance_id) when is_atom(instance_id) do
    random_unsafe(name, 1)
    |> List.first()
  end

  def random(name, instance_id) when is_integer(instance_id) do
    random(name, 1, instance_id)
    |> List.first()
  end

  def random(name, number, instance_id) do
    file_path = name_to_file(name)

    xs =
      Path.join([:code.priv_dir(:rc), "data/name/", file_path])
      |> File.stream!()
      |> Enum.to_list()

    # When starting an instance this is among the first Game.calls executed
    # and the registry may not have the rand agent yet (worse under many
    # simultaneous instance boots); the error result used to crash the
    # caller — e.g. the character market filling its slots at creation.
    # Instance.Rand.Safe falls back to an unseeded draw (names are cosmetic)
    # behind a circuit breaker.
    Instance.Rand.Safe.take_random(instance_id, xs, number)
    |> Enum.map(&String.trim/1)
  end

  @doc """
  random_unsafe/2 must not be used in game- or instance- related modules because
  it is not seeded. Use random/2 or random/3 instead
  """
  def random_unsafe(name, number) do
    file_path = name_to_file(name)

    Path.join([:code.priv_dir(:rc), "data/name/", file_path])
    |> File.stream!()
    |> Enum.to_list()
    |> Enum.take_random(number)
    |> Enum.map(fn name -> String.trim(name) end)
  end
end
