defmodule Portal.RegistrationView do
  use Portal, :view
  import Phoenix.View, only: [render_one: 3, render_many: 3, render_one: 4, render_many: 4]
  alias Portal.RegistrationView

  # The listing endpoint (GET /instances/:iid/registrations) renders every
  # registration in the instance to any authenticated caller who passes the
  # `:group_resource` gate. The per-player `token` field is a long-lived
  # bearer credential — sensitive even though the channel layer also binds
  # it to the JWT account via RC.Registrations.valid?/3. We include it
  # ONLY on registrations whose profile belongs to the calling account, so
  # players can pick up their own token but never anyone else's.
  def render("index.json", %{registrations: registrations, caller_account_id: aid}) do
    render_many(registrations, RegistrationView, "registration_listing.json", caller_account_id: aid)
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

  def render("registration_listing.json", %{registration: registration, caller_account_id: aid}) do
    %{
      id: registration.id,
      state: registration.state
    }
    |> maybe_put_token(registration, aid)
    |> maybe_put_faction(registration)
    |> maybe_put_profile(registration)
  end

  # Only attach the token if this registration's profile belongs to the
  # caller. Anything else and the field is omitted entirely (so the SPA
  # never sees other players' tokens).
  defp maybe_put_token(view, registration, caller_account_id) do
    cond do
      not Ecto.assoc_loaded?(registration.profile) ->
        view

      registration.profile.account_id == caller_account_id ->
        Map.put(view, :token, registration.token)

      true ->
        view
    end
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
