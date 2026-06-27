defmodule Portal.AccountView do
  use Portal, :view
  import Phoenix.View, only: [render_one: 3, render_many: 3, render_one: 4, render_many: 4]
  alias Portal.AccountView

  def render("index.json", %{accounts: accounts}) do
    render_many(accounts, AccountView, "account.json")
  end

  def render("show.json", %{account: account}) do
    render_one(account, AccountView, "account.json")
  end

  def render("account.json", %{account: account}) do
    view = %{
      id: account.id,
      email: account.email,
      name: account.name,
      role: account.role,
      status: account.status,
      settings: Map.merge(account.settings, %{lang: account.lang}),
      money: account.money,
      is_free: account.is_free,
      # `discord_id` is shown to the owner (via /account) and to admins
      # (via /accounts/:aid) so the linking UI can render "currently
      # linked" state. `nil` when unlinked. Steam ID is intentionally
      # absent here — it's set into the Vue store by the steam-auth
      # callback, not from this endpoint.
      discord_id: account.discord_id
    }

    if Ecto.assoc_loaded?(account.profiles),
      do: Map.put(view, :profiles, render_many(account.profiles, Portal.ProfileView, "profile.json", as: :profile)),
      else: view
  end
end
