defmodule SystemAI.Trees do
  @moduledoc """
  Registry for the behavior trees that are NOT the vanilla "Dominion" tree.

  The vanilla tree still rides on the galaxy agent (`:get_behavior_tree`), which
  keeps the neutral-system AI and its tests byte-identical. Additional trees —
  today the Wave Defense "Rebel Dominion" tree — are declared in config:

      config :rc, RC.SystemAI,
        trees: [rebel_dominion: {"data/system_ai/behavior_tree_wave.json", "Rebel Dominion"}]

  and parsed once per BEAM on first use, then served from `:persistent_term`.
  Trees are immutable data, so there is no reason to copy them into every
  galaxy snapshot or to round-trip a galaxy call per AI evaluation. Editing a
  tree JSON therefore needs a node restart (or `reload/1`) to take effect.
  """

  @doc "The parsed tree for `key`. Raises on an unknown key or a bad file."
  def get(key) when is_atom(key) do
    case :persistent_term.get({__MODULE__, key}, nil) do
      nil -> reload(key)
      tree -> tree
    end
  end

  @doc "Re-parse `key` from disk and replace the cached copy."
  def reload(key) when is_atom(key) do
    {path, name} =
      case Keyword.fetch(configured(), key) do
        {:ok, spec} -> spec
        :error -> raise ArgumentError, "no behavior tree configured for #{inspect(key)}"
      end

    tree = Instance.SystemAI.Parser.parse!(Path.join(:code.priv_dir(:rc), path), name)
    :persistent_term.put({__MODULE__, key}, tree)
    tree
  end

  @doc "Configured tree keys."
  def keys, do: Keyword.keys(configured())

  defp configured do
    :rc
    |> Application.get_env(RC.SystemAI, [])
    |> Keyword.get(:trees, [])
  end
end
