defmodule Edict.Scenario do
  @moduledoc """
  A scenario script's setup: validating what the `setup` block declares, and
  turning it into the `game_data` the engine boots.

  The setup is a closed form. Each field (`Edict.Catalog` lists them) has a
  type and bounds, and every key that names game content (mutators, patents)
  must exist in the game's own catalogs. The result feeds the same generator
  the daily challenge uses (`Daily.Generator.build/2`), so a scripted scenario
  gets the daily's whole world-building pipeline: the procedural system, the
  sector of empty or neutral neighbors, the rival court, mutators, granted
  and discounted patents.
  """

  alias Edict.{Catalog, Interpreter}

  @doc """
  Validate setup fields (`%{name => value}`, as the setup block assigned them)
  and fill in defaults. Returns `{:ok, config}` or `{:error, [diag]}`.
  """
  def config(fields) when is_map(fields) do
    errors =
      Enum.flat_map(fields, fn {name, value} ->
        case check(name, value) do
          :ok -> []
          {:error, message} -> [%{message: "setup #{name}: #{message}", node_id: nil, at: nil}]
        end
      end)

    if errors == [] do
      config =
        Catalog.setup_defaults()
        |> Map.merge(fields)
        |> Map.update!("time_limit", &(&1 / 1))
        |> Map.update!("systems", &trunc/1)

      {:ok, config}
    else
      {:error, errors}
    end
  end

  defp check("name", v), do: text(v, 60)
  defp check("description", v), do: text(v, 500)

  defp check("time_limit", v) do
    {lo, hi} = Catalog.setup_bounds()["time_limit"]

    if is_number(v) and v >= lo and v <= hi,
      do: :ok,
      else: {:error, "must be between #{div(lo, 60)}m and #{div(hi, 60)}m"}
  end

  defp check("faction", v) do
    if v == nil or v in Catalog.factions(),
      do: :ok,
      else: {:error, "must be one of #{Enum.join(Catalog.factions(), ", ")}"}
  end

  defp check("systems", v) do
    {lo, hi} = Catalog.setup_bounds()["systems"]

    if is_number(v) and v == Float.round(v / 1) and v >= lo and v <= hi,
      do: :ok,
      else: {:error, "must be a whole number from #{lo} to #{hi}"}
  end

  defp check("neighbors", v),
    do: if(v in ["empty", "neutral"], do: :ok, else: {:error, "must be \"empty\" or \"neutral\""})

  defp check("rival", v), do: if(is_boolean(v), do: :ok, else: {:error, "must be true or false"})
  defp check("mutators", v), do: keys(v, Catalog.mutator_keys(), 6, "mutator")
  defp check("grant_patents", v), do: keys(v, Catalog.patent_keys(), 30, "patent")

  defp check("patent_discounts", v) when is_map(v) do
    known = Catalog.patent_keys()

    cond do
      map_size(v) > 30 ->
        {:error, "30 discounts at most"}

      Enum.any?(Map.keys(v), &(&1 not in known)) ->
        {:error, "unknown patent #{inspect(Enum.find(Map.keys(v), &(&1 not in known)))}"}

      Enum.any?(Map.values(v), &(not is_number(&1) or &1 < 0.05 or &1 > 1)) ->
        {:error, "each factor must be between 5% and 100%"}

      true ->
        :ok
    end
  end

  defp check("patent_discounts", _), do: {:error, "must be a record such as {capital_1: 20%}"}

  defp check("seed", v) do
    if is_number(v) or (is_binary(v) and byte_size(v) <= 64),
      do: :ok,
      else: {:error, "must be a number or a short text"}
  end

  defp check(name, _v), do: {:error, "#{name} isn't a setup field"}

  defp text(v, max) do
    cond do
      not is_binary(v) -> {:error, "must be text"}
      String.length(v) > max -> {:error, "#{max} characters at most"}
      true -> :ok
    end
  end

  defp keys(v, known, max, what) when is_list(v) do
    cond do
      length(v) > max -> {:error, "#{max} at most"}
      Enum.any?(v, &(not is_binary(&1))) -> {:error, "list #{what}s by their key, as text"}
      (bad = Enum.find(v, &(&1 not in known))) != nil -> {:error, "unknown #{what} #{inspect(bad)}"}
      true -> :ok
    end
  end

  defp keys(_v, _known, _max, what), do: {:error, "must be a list of #{what} keys"}

  @doc "The scenario's faction: the setup's, or one picked from the seed."
  def faction(config, seed) do
    case config["faction"] do
      nil ->
        <<byte, _::binary>> = :crypto.hash(:sha256, "edict-faction:" <> Interpreter.to_text(seed))
        Enum.at(Catalog.factions(), rem(byte, length(Catalog.factions())))

      faction ->
        faction
    end
  end
end
