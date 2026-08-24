defmodule RC.Accounts.Emails do
  @moduledoc """
  Transactional email content, rendered in-repo.

  Replaces the former Mailjet server-side templates (the MAILER_*_TEMPLATE
  ids): subject, HTML and text bodies now live here, so the provider only
  needs a raw-send API — AWS SES via `Swoosh.Adapters.ExAwsAmazonSES` in
  prod, `Local`/`Test` elsewhere.

  `build/3` keeps the historical template atoms (`:verification_template`,
  `:password_reset_template`, `:email_update_template`, `:web_bind_template`)
  so callers of `RC.Accounts.send_email_template/3` are unchanged. Link paths
  are the ones the SPA routes on — see `Portal` login/bind/reset pages.
  """

  import Swoosh.Email

  # Palette lifted from the game/portal UI (front/src/styles/shared/
  # variables.scss and assets/css/_variables.scss): teal $primary accents
  # over the charcoal $grey #282c34 family, $white/$light-grey text. The
  # earlier white-and-gold shell predated this theming pass.
  @accent "#00b89a"
  @page_bg "#191c22"
  @card_bg "#282c34"
  @card_border "#3c414d"
  @heading_text "#e6e6e6"
  @body_text "#bababa"
  @muted_text "#7d8390"
  @button_text "#0b2a23"

  @doc """
  Build a `%Swoosh.Email{}` for `template`, addressed per template semantics
  (email-update and web-bind go to the token's `candidate_email`, the rest to
  the account's email).
  """
  def build(template, account, token) do
    mailer_config = Application.get_env(:rc, RC.Mailer)
    base_url = Application.get_env(:rc, :rc_domain)

    {subject, heading, intro, cta, outro} = content(template, link(base_url, token, template))

    email =
      new()
      |> from(Keyword.get(mailer_config, :sender))
      |> to(destination(account, token, template))
      |> subject(subject)
      |> html_body(render_html(heading, intro, cta, outro))
      |> text_body(render_text(heading, intro, cta, outro))

    case Keyword.get(mailer_config, :configuration_set) do
      nil -> email
      set -> put_provider_option(email, :configuration_set_name, set)
    end
  end

  defp destination(account, token, template) when template in [:email_update_template, :web_bind_template],
    do: {account.name, token.candidate_email}

  defp destination(account, _token, _template), do: {account.name, account.email}

  defp link(base_url, token, :verification_template),
    do: base_url <> "login/?action=validate-registration&token=#{token.value}"

  defp link(base_url, token, :password_reset_template),
    do: base_url <> "reset-password/?token=#{token.value}"

  defp link(base_url, token, :email_update_template),
    do: base_url <> "login/?action=validate-email-update&token=#{token.value}"

  defp link(base_url, token, :web_bind_template),
    do: base_url <> "bind/?token=#{token.value}"

  defp link(base_url, token, :account_deletion_template),
    do: base_url <> "login/?action=confirm-deletion&token=#{token.value}"

  defp link(_base_url, _token, :account_deleted_template), do: nil

  # Tokenless — points at the public forgotten-password page. Sent (rate
  # capped) when a signup collides with an existing active account, so the
  # signup response itself never has to reveal the collision.
  defp link(base_url, _token, :existing_account_template), do: base_url <> "forgotten-password/"

  defp content(:verification_template, link) do
    {"Confirm your email - Tetrarchy Falls", "Confirm your email",
     "Welcome, Tetrarch. Confirm your email address to activate your account.",
     {"Confirm email", link},
     "If you did not create an account on tetrarchyfalls.com, you can ignore this email."}
  end

  defp content(:password_reset_template, link) do
    {"Reset your password - Tetrarchy Falls", "Reset your password",
     "We received a request to reset the password for your account. Use the link below to choose a new one. " <>
       expiry_note(),
     {"Reset password", link},
     "If you did not request a password reset, you can ignore this email. Your password is unchanged."}
  end

  defp content(:email_update_template, link) do
    {"Confirm your new email address - Tetrarchy Falls", "Confirm your new email address",
     "You asked to change the email address on your Tetrarchy Falls account to this one. " <>
       "Confirm the change with the link below. " <> expiry_note(),
     {"Confirm new address", link},
     "If you did not request this change, you can ignore this email. The address on your account will not change."}
  end

  defp content(:web_bind_template, link) do
    {"Link your account - Tetrarchy Falls", "Link your account",
     "Use the link below to connect this email address to your Tetrarchy Falls account. " <> expiry_note(),
     {"Link account", link},
     "If you did not request this, you can ignore this email."}
  end

  defp content(:account_deletion_template, link) do
    grace = RC.Accounts.Deletion.grace_days()

    {"Confirm account deletion - Tetrarchy Falls", "Confirm account deletion",
     "We received a request to permanently delete your Tetrarchy Falls account. " <>
       "If you confirm, your account will be locked for #{grace} days and then permanently deleted. " <>
       "You can log back in at any time during those #{grace} days to cancel. " <>
       expiry_note(:account_deletion),
     {"Confirm deletion", link},
     "If you did not request this, do not click the button. Your account will not be changed. " <>
       "If you think someone else has access to your account, please change your password."}
  end

  defp content(:existing_account_template, link) do
    {"You already have an account - Tetrarchy Falls", "You already have an account",
     "Someone — probably you — just tried to create a Tetrarchy Falls account with this email " <>
       "address, but it already has one. If that was you, simply log in — or reset your password below.",
     {"Reset password", link},
     "If this wasn't you, you can ignore this email. Your account is unchanged."}
  end

  defp content(:account_deleted_template, _link) do
    {"Your account has been deleted - Tetrarchy Falls", "Your account has been deleted",
     "Your Tetrarchy Falls account and its personal data have been permanently deleted. " <>
       "Your game history now appears under an anonymous \"Erased\" name that is not linked to you. " <>
       "Backup copies expire within 30 days.", nil,
     "This is the last email we will send to this address. o7, Tetrarch."}
  end

  defp expiry_note(type \\ nil) do
    config = Application.get_env(:rc, RC.Accounts.AccountToken)

    hours =
      config
      |> Keyword.get(:validity_overrides, [])
      |> Keyword.get(type, Keyword.get(config, :validity_time, 7200))
      |> div(3600)
      |> max(1)

    "The link expires in #{hours} hour#{if hours == 1, do: "", else: "s"}."
  end

  # Tables + bgcolor attributes rather than styled divs: Outlook's Word
  # renderer drops background-color on divs, which would leave the light
  # text unreadable on white.
  defp render_html(heading, intro, cta, outro) do
    """
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="#{@page_bg}" style="margin:0;background-color:#{@page_bg};font-family:Verdana,Geneva,sans-serif;">
      <tr>
        <td align="center" style="padding:32px 16px;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="#{@card_bg}" style="max-width:520px;background-color:#{@card_bg};border:1px solid #{@card_border};border-top:4px solid #{@accent};">
            <tr>
              <td style="padding:32px 36px;">
                <p style="margin:0 0 4px 0;font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#{@accent};">Tetrarchy Falls</p>
                <h1 style="margin:0 0 16px 0;font-size:20px;color:#{@heading_text};">#{heading}</h1>
                <p style="margin:0 0 24px 0;font-size:14px;line-height:1.6;color:#{@body_text};">#{intro}</p>
    #{cta_html(cta)}
                <p style="margin:0;font-size:12px;line-height:1.6;color:#{@muted_text};">#{outro}</p>
              </td>
            </tr>
            <tr>
              <td style="padding:16px 36px;border-top:1px solid #{@card_border};">
                <p style="margin:0;font-size:11px;color:#{@muted_text};">Tetrarchy Falls · <a href="https://tetrarchyfalls.com" style="color:#{@muted_text};">tetrarchyfalls.com</a></p>
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
    """
  end

  defp cta_html(nil), do: ""

  defp cta_html({cta_label, cta_link}) do
    """
                <p style="margin:0 0 24px 0;">
                  <a href="#{cta_link}" style="display:inline-block;padding:12px 28px;background-color:#{@accent};color:#{@button_text};font-size:14px;font-weight:bold;text-decoration:none;">#{cta_label}</a>
                </p>
                <p style="margin:0 0 24px 0;font-size:12px;line-height:1.6;color:#{@muted_text};">Or paste this link into your browser:<br/><a href="#{cta_link}" style="color:#{@accent};word-break:break-all;">#{cta_link}</a></p>
    """
  end

  defp render_text(heading, intro, cta, outro) do
    """
    Tetrarchy Falls - #{heading}

    #{intro}
    #{cta_text(cta)}
    #{outro}

    --
    Tetrarchy Falls · https://tetrarchyfalls.com
    """
  end

  defp cta_text(nil), do: ""
  defp cta_text({cta_label, cta_link}), do: "\n#{cta_label}: #{cta_link}\n"
end
