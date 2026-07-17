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

  @doc """
  The full name list `name`, trimmed, in file order. For callers that build a
  without-replacement pool (see unique/3) rather than draw with replacement.
  """
  def all(name) do
    file_path = name_to_file(name)

    Path.join([:code.priv_dir(:rc), "data/name/", file_path])
    |> File.stream!()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
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
    xs = all(name)

    # since when starting an instance this is the first Game.call to be executed,
    # the registry might take a short while to be updated hence attempts=5
    Game.call(instance_id, :rand, :master, {:take_random, xs, number}, 5)
  end

  @doc """
  random_unsafe/2 must not be used in game- or instance- related modules because
  it is not seeded. Use random/2 or random/3 instead
  """
  def random_unsafe(name, number) do
    all(name)
    |> Enum.take_random(number)
  end

  @doc """
  `count` names from list `name`, globally unique, dealt off a single seeded
  shuffle of the whole list.

  The shuffle is one call to the instance's :rand agent, so for a given seed
  the sequence is fully deterministic even if the caller then fans the names
  out to concurrent tasks. The "place" list carries 11k names, so a
  10,000-system galaxy never overflows it (bin/gen_place_names.exs regrows
  the pool if that ceiling ever moves). Should `count` still exceed the list,
  it cycles with a numeric generation suffix ("Acha 2", "Acha 3", …) —
  digits, because stellar bodies already use roman numerals ("Acha II" is a
  planet of Acha), and a suffix, so typing a system's name in search still
  narrows straight to it.
  """
  def unique(name, count, instance_id) do
    xs = all(name)
    shuffled = Game.call(instance_id, :rand, :master, {:take_random, xs, length(xs)}, 5)
    extend_unique(shuffled, count)
  end

  @doc false
  # Pure overflow extension of a shuffled base list — public for unit tests.
  def extend_unique(shuffled, count) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.flat_map(fn
      0 -> shuffled
      round -> Enum.map(shuffled, &"#{&1} #{round + 1}")
    end)
    |> Enum.take(count)
  end
end
