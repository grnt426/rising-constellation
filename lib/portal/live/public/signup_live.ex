defmodule Portal.SignupLive do
  use Portal, :live_view

  # Open signup (un-retired with the SES migration): accounts start as
  # :registered and must confirm their email before they can act — see
  # Portal.Plug.VerificationGate. Invite links still work on LandingLive
  # and now grant referral credit instead of bypassing verification.
  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end
