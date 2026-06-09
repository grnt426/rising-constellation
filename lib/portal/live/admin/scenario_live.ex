defmodule Portal.ScenarioLive do
  use Portal, :admin_live_view

  require Logger

  alias RC.Scenarios

  @impl true
  def handle_params(params, _, socket) do
    scenario = Scenarios.get_scenario(Map.get(params, "sid"))

    if scenario != nil do
      {:noreply, assign(socket, scenario: scenario)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update", params, socket) do
    scenario = Scenarios.get_scenario(Map.get(params, "scenario"))

    case Scenarios.update_scenario(scenario, params) do
      {:ok, scenario} ->
        scenario = Scenarios.get_scenario(scenario.id)
        {:noreply, assign(socket, scenario: scenario)}

      {:error, _} ->
        IO.inspect("scenario not found")
        {:noreply, socket}
    end
  end

  # Discord lobby automation — flip the discord_ready flag in place.
  # Same pattern as Portal.AccountLive.toggle_is_bot — fetch fresh
  # before the read-then-write, no admin-actor check needed because
  # the LiveView itself is admin-gated (`use Portal, :admin_live_view`).
  @impl true
  def handle_event("toggle_discord_ready", _params, socket) do
    scenario = Scenarios.get_scenario(socket.assigns.scenario.id)

    case Scenarios.set_scenario_discord_ready(scenario, not scenario.discord_ready) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:scenario, updated)
         |> put_flash(
           :info,
           gettext("Discord ready flipped to %{value}", value: updated.discord_ready)
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("discord_ready toggle failed"))}
    end
  end
end
