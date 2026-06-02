defmodule Portal.RankingsView do
  use Portal, :view
  import Phoenix.View, only: [render_one: 3, render_many: 3, render_one: 4, render_many: 4]

  alias Portal.RankingsView

  def render("standings.json", %{profiles: profiles}) do
    render_many(profiles, RankingsView, "ranked_profile.json", as: :profile)
  end

  def render("ranked_profile.json", %{profile: profile}) do
    %{
      id: profile.id,
      name: profile.name,
      avatar: profile.avatar,
      full_name: profile.full_name,
      # Stage 8 F6 — round ELO to the same granularity the UI shows
      # (`{{ standing.elo | integer }}` in Standings.vue). The wire
      # previously carried up to 3-decimal floats from
      # `RC.Rankings.change_by_faction`, letting a wire reader
      # disambiguate ties, detect ranked-game participation that the
      # integer UI hides, and infer per-match deltas. The admin
      # LiveViews already call `round/1` for the same reason.
      elo: round(profile.elo)
    }
  end
end
