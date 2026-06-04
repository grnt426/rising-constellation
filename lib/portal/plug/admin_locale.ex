defmodule Portal.Plug.AdminLocale do
  @moduledoc """
  Sets `Portal.Gettext`'s process locale from the authenticated admin's
  `Account.lang` so the initial HTTP render of the admin root layout
  (which executes in the request process, *not* the LiveView process)
  honors the user's language preference.

  Must run AFTER `Guardian.Plug.EnsureAuthenticated` so the user is
  available in `conn.private.guardian_default_resource`. The companion
  `Portal.AdminAuth.on_mount/4` hook re-applies the same locale inside
  the LiveView process for subsequent template renders.
  """

  alias RC.Accounts.Account

  @supported ~w(en fr)

  def init(opts), do: opts

  def call(conn, _opts) do
    Gettext.put_locale(Portal.Gettext, locale_from(conn))
    conn
  end

  defp locale_from(%{private: %{guardian_default_resource: %Account{lang: lang}}})
       when lang in @supported,
       do: lang

  defp locale_from(_), do: "en"
end
