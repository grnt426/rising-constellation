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
      elo: profile.elo
    }
  end
end
