defmodule Portal.InstanceOg do
  @moduledoc """
  OpenGraph metadata for a game lobby (/portal/instance/:id), in the
  same shape `Portal.ForgeOg.data/2` returns so `Portal.ForgeOg.meta_tags/2`
  renders it: the game's name, its description plus a facts line (speed,
  mode, factions, galaxy size, status), and the source scenario's galaxy
  thumbnail.

  Which lobbies unfurl is RC.Instances.viewable?/3 with no viewer: any
  game behind its share token, publicly listed games behind a numeric
  id. The thumbnail comes from the scenario even when that scenario is
  still a Forge draft: whoever can see the game can see its map.
  """

  alias RC.Instances.Instance

  @description_limit 200

  def data(%Instance{} = instance) do
    meta = instance.game_metadata || %{}

    %{
      title: instance.name || Map.get(meta, "name") || "Tetrarchy Falls game",
      description: describe(instance, meta),
      image: thumbnail(instance)
    }
  end

  defp thumbnail(%{scenario_id: sid}) when is_integer(sid) do
    case RC.Repo.get(RC.Scenarios.Scenario, sid) do
      nil -> nil
      scenario -> Portal.ThumbnailUrl.absolute_url(scenario)
    end
  end

  defp thumbnail(_), do: nil

  defp describe(instance, meta) do
    blurb =
      case instance.description || Map.get(meta, "description") do
        text when is_binary(text) -> text |> String.trim() |> truncate()
        _ -> ""
      end

    facts =
      [
        speed_name(Map.get(meta, "speed")),
        mode_name(game_mode(instance, meta)),
        count(Map.get(meta, "factions"), "faction"),
        systems(Map.get(meta, "system_number")),
        status(instance)
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")

    [blurb, facts]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" — ")
  end

  defp game_mode(instance, meta) do
    (instance.game_data || %{})["game_mode_type"] || Map.get(meta, "game_mode_type")
  end

  defp speed_name("fast"), do: "Flash"
  defp speed_name("medium"), do: "Tactic"
  defp speed_name("slow"), do: "Legacy"
  defp speed_name(_), do: nil

  defp mode_name("wave"), do: "Rebel Defense"
  defp mode_name("ranked"), do: "Ranked"
  defp mode_name("casual"), do: "Casual"
  defp mode_name(_), do: nil

  defp count(list, noun) when is_list(list) and list != [],
    do: "#{length(list)} #{noun}#{if length(list) == 1, do: "", else: "s"}"

  defp count(_, _), do: nil

  defp systems(n) when is_integer(n), do: "#{n} systems"
  defp systems(_), do: nil

  defp status(%{state: "open", registration_status: :preregistration}), do: "Pre-registration"
  defp status(%{state: "open", registration_status: :closed}), do: "Registration closed"
  defp status(%{state: "open"}), do: "Open for registration"
  defp status(%{state: state}) when state in ["running", "paused", "not_running"], do: "In progress"
  defp status(%{state: "ended"}), do: "Ended"
  defp status(_), do: nil

  defp truncate(text) do
    if String.length(text) > @description_limit,
      do: String.slice(text, 0, @description_limit - 1) <> "…",
      else: text
  end
end
