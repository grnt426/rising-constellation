defmodule Portal.RegistrationView do
  use Portal, :view
  import Phoenix.View, only: [render_one: 3, render_many: 3, render_one: 4, render_many: 4]
  alias Portal.RegistrationView

  # Stage 2 #7 — the listing endpoint (GET /instances/:iid/registrations)
  # NEVER includes `:token`. The per-player token is a long-lived bearer
  # credential; even with the JWT-binding in RC.Registrations.valid?/3
  # (Stage 3 #1) we keep defense in depth and omit it from listings
  # unconditionally. Callers that need their own token must fetch their
  # specific registration via GET /api/registrations/:id, which checks
  # caller ownership before returning the `show.json` (token-bearing)
  # shape.
  def render("index.json", %{registrations: registrations}) do
    render_many(registrations, RegistrationView, "registration_listing.json")
  end

  def render("show.json", %{registration: registration}) do
    render_one(registration, RegistrationView, "registration.json")
  end

  def render("registration.json", %{registration: registration}) do
    %{
      id: registration.id,
      token: registration.token,
      state: registration.state
    }
    |> maybe_put_faction(registration)
    |> maybe_put_profile(registration)
  end

  def render("registration_listing.json", %{registration: registration}) do
    %{
      id: registration.id,
      state: registration.state
    }
    |> maybe_put_faction(registration)
    |> maybe_put_profile(registration)
  end

  defp maybe_put_faction(view, registration) do
    if Ecto.assoc_loaded?(registration.faction),
      do: Map.put(view, :faction, render_one(registration.faction, Portal.FactionView, "faction.json", as: :faction)),
      else: view
  end

  defp maybe_put_profile(view, registration) do
    if Ecto.assoc_loaded?(registration.profile),
      do: Map.put(view, :profile, render_one(registration.profile, Portal.ProfileView, "profile.json", as: :profile)),
      else: view
  end

  def render("registrations_export_fragment.json", %{registration: registration}) do
    %{
      id: registration.id,
      faction_id: registration.faction_id,
      profile_id: registration.profile_id,
      inserted_at: registration.inserted_at
    }
  end
end
