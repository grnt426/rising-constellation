defmodule Edict.Effects do
  @moduledoc """
  The gate between a script's effects and the game.

  The interpreter already checks each action's arguments against the catalog
  (types, choices, bounds). This module is the host's own check, done again
  against the world the effects were produced for, so a mistake in the
  interpreter can't become a game action:

    * only the actions in the catalog pass; anything else is dropped;
    * a target must be one of the player's **own** systems (an id from the
      world the script read), never an arbitrary id;
    * text is cleaned for display: control characters and text-direction
      overrides removed, length capped. Clients render it as plain text;
    * `send_agent` needs a scenario with a rival court;
    * messages are rate-limited across pulses, so a script can't flood the
      player.

  `prepare/4` returns the effects to apply and the ones it refused (with a
  reason), plus the updated rate-limit state.
  """

  @max_message 280
  @notify_per_minute 20
  @bidi [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F]

  defstruct notify_times: []

  def new, do: %__MODULE__{}

  @doc """
  Check `effects` produced at time `t` against `world` and the scenario
  `config`. Returns `{accepted, refused, state}`.
  """
  def prepare(effects, world, config, %__MODULE__{} = state, t) do
    own = own_systems(world)
    home = List.first(own)

    {accepted, refused, state} =
      Enum.reduce(effects, {[], [], state}, fn effect, {ok, bad, state} ->
        case check(effect, own, home, config, state, t) do
          {:ok, clean, state} -> {[clean | ok], bad, state}
          {:error, reason} -> {ok, [%{effect: effect, reason: reason} | bad], state}
        end
      end)

    {Enum.reverse(accepted), Enum.reverse(refused), state}
  end

  defp check(%{"action" => action, "args" => args} = effect, own, home, config, state, t) when is_map(args) do
    case action do
      a when a in ["give", "take"] ->
        with {:ok, resource} <- one_of(args["resource"], Edict.Catalog.resources()),
             {:ok, amount} <- bounded(args["amount"], 0, 1.0e9) do
          {:ok, %{effect | "args" => %{"resource" => resource, "amount" => amount}}, state}
        end

      "notify" ->
        with {:ok, message} <- message(args["message"]),
             {:ok, tone} <- one_of(Map.get(args, "tone", "info"), ["info", "good", "warning"]),
             {:ok, state} <- notify_budget(state, t) do
          {:ok, %{effect | "args" => %{"message" => message, "tone" => tone}}, state}
        end

      "finish" ->
        message =
          case args["message"] do
            nil -> {:ok, nil}
            m -> message(m)
          end

        with {:ok, m} <- message, do: {:ok, %{effect | "args" => %{"message" => m}}, state}

      "destabilize" ->
        with {:ok, amount} <- bounded(args["amount"], 0, 100),
             {:ok, system} <- own_system(Map.get(args, "system"), own, home) do
          {:ok, %{effect | "args" => %{"amount" => amount, "system" => system}}, state}
        end

      "send_agent" ->
        with true <- config["rival"] == true || {:error, "the scenario has no rival court"},
             {:ok, "erased"} <- one_of(args["type"], ["erased"]),
             {:ok, level} <- bounded(Map.get(args, "level", 1), 1, 30),
             {:ok, system} <- own_system(Map.get(args, "system"), own, home) do
          {:ok, %{effect | "args" => %{"type" => "erased", "level" => Float.round(level), "system" => system}}, state}
        end

      _ ->
        {:error, "unknown action"}
    end
  end

  defp check(_effect, _own, _home, _config, _state, _t), do: {:error, "malformed effect"}

  defp own_systems(world) do
    world
    |> get_in(["player", "systems"])
    |> List.wrap()
    |> Enum.map(&Map.get(&1, "id"))
    |> Enum.filter(&is_number/1)
  end

  # A target must be one of the player's own systems; none given means home.
  defp own_system(nil, _own, nil), do: {:error, "the player has no system"}
  defp own_system(nil, _own, home), do: {:ok, home}

  defp own_system(id, own, _home) when is_number(id) do
    if Enum.any?(own, &(&1 == id)), do: {:ok, id}, else: {:error, "system #{id} isn't one of the player's"}
  end

  defp own_system(_, _own, _home), do: {:error, "system: must be a system id"}

  defp one_of(v, allowed), do: if(v in allowed, do: {:ok, v}, else: {:error, "#{Edict.AST.quoted(v)} isn't allowed"})

  defp bounded(v, lo, hi) when is_number(v) and v >= lo and v <= hi, do: {:ok, v / 1}
  defp bounded(_v, lo, hi), do: {:error, "must be a number from #{lo} to #{hi}"}

  @doc "Clean text for display: no control or direction characters, capped length."
  def clean_text(text, max \\ @max_message)

  def clean_text(text, max) when is_binary(text) do
    cleaned =
      text
      |> String.to_charlist()
      |> Enum.reject(fn cp -> cp in @bidi or (cp < 0x20 and cp != ?\n) or (cp >= 0x7F and cp < 0xA0) end)
      |> List.to_string()
      |> String.trim()

    if String.length(cleaned) > max,
      do: String.slice(cleaned, 0, max - 1) <> "…",
      else: cleaned
  end

  defp message(m) when is_binary(m) do
    case clean_text(m) do
      "" -> {:error, "empty message"}
      text -> {:ok, text}
    end
  end

  defp message(_), do: {:error, "a message must be text"}

  defp notify_budget(state, t) do
    recent = Enum.filter(state.notify_times, &(&1 > t - 60))

    if length(recent) >= @notify_per_minute,
      do: {:error, "too many messages (#{@notify_per_minute} a minute at most)"},
      else: {:ok, %{state | notify_times: [t | recent]}}
  end
end
