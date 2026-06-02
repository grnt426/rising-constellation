defmodule Portal.ScenarioView do
  use Portal, :view
  import Phoenix.View, only: [render_one: 3, render_many: 3]
  alias Portal.ScenarioView

  def render("index.json", %{scenarios: scenarios}) do
    render_many(scenarios, ScenarioView, "scenario_partial.json")
  end

  def render("show.json", %{scenario: scenario}) do
    render_one(scenario, ScenarioView, "scenario_full.json")
  end

  def render("scenario_full.json", %{scenario: scenario}) do
    %{
      id: scenario.id,
      game_data: scenario.game_data,
      game_metadata: scenario.game_metadata,
      is_official: scenario.is_official,
      published_at: scenario.published_at,
      author: render_author(scenario.author),
      thumbnail: scenario.thumbnail,
      likes: scenario.likes,
      dislikes: scenario.dislikes,
      favorites: scenario.favorites
    }
  end

  def render("scenario_partial.json", %{scenario: scenario}) do
    %{
      id: scenario.id,
      game_metadata: scenario.game_metadata,
      is_official: scenario.is_official,
      published_at: scenario.published_at,
      author: render_author(scenario.author),
      thumbnail: scenario.thumbnail,
      likes: scenario.likes,
      dislikes: scenario.dislikes,
      favorites: scenario.favorites
    }
  end

  # See Portal.MapView.render_author/1 — same reasoning here.
  defp render_author(%RC.Accounts.Account{} = author), do: %{id: author.id, name: author.name}
  defp render_author(_), do: nil
end
