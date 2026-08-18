defmodule Portal.ProfileView do
  use Portal, :view
  import Phoenix.View, only: [render_one: 3, render_many: 3, render_one: 4, render_many: 4]
  alias Portal.ProfileView

  def render("index.json", %{profiles: profiles}) do
    render_many(profiles, ProfileView, "profile.json")
  end

  def render("show.json", %{profile: profile} = assigns) do
    view = render_one(profile, ProfileView, "profile.json")

    # Aggregate game stats (RC.ProfileStats.for_profile/1) ride along on
    # the public single-profile endpoint only — never on list renders,
    # which would multiply the queries.
    case assigns[:stats] do
      nil -> view
      stats -> Map.put(view, :stats, stats)
    end
  end

  def render("profile.json", %{profile: profile}) do
    view = %{
      id: profile.id,
      name: profile.name,
      avatar: profile.avatar,
      full_name: profile.full_name,
      description: profile.description,
      long_description: profile.long_description,
      favorite_faction: profile.favorite_faction,
      favorite_icon: profile.favorite_icon
    }

    if Ecto.assoc_loaded?(profile.registrations),
      do:
        Map.put(
          view,
          :registrations,
          render_many(profile.registrations, Portal.RegistrationView, "registration.json", as: :registration)
        ),
      else: view
  end
end
