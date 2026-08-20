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

  @accent "#c19a3d"

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

  defp content(:verification_template, link) do
    {"Confirm your email — Tetrarchy Falls", "Confirm your email",
     "Welcome, Tetrarch. Confirm your email address to activate your account and take your place among the stars.",
     {"Confirm email", link},
     "If you did not create an account on tetrarchyfalls.com, you can safely ignore this email."}
  end

  defp content(:password_reset_template, link) do
    {"Reset your password — Tetrarchy Falls", "Reset your password",
     "We received a request to reset the password for your account. Use the link below to choose a new one. " <>
       expiry_note(),
     {"Reset password", link},
     "If you did not request a password reset, you can safely ignore this email — your password is unchanged."}
  end

  defp content(:email_update_template, link) do
    {"Confirm your new email address — Tetrarchy Falls", "Confirm your new email address",
     "You asked to change the email address on your Tetrarchy Falls account to this one. Confirm it with the link below. " <>
       expiry_note(),
     {"Confirm new address", link},
     "If you did not request this change, you can safely ignore this email and the address on the account stays as it was."}
  end

  defp content(:web_bind_template, link) do
    {"Link your account — Tetrarchy Falls", "Link your account",
     "Use the link below to finish connecting this email address to your Tetrarchy Falls account. " <> expiry_note(),
     {"Link account", link},
     "If you did not request this, you can safely ignore this email."}
  end

  defp content(:account_deletion_template, link) do
    grace = RC.Accounts.Deletion.grace_days()

    {"Confirm account deletion — Tetrarchy Falls", "Confirm account deletion",
     "We received a request to permanently delete your Tetrarchy Falls account. " <>
       "Confirming starts a #{grace}-day countdown: during it your account is locked, " <>
       "and logging back in lets you cancel at any time before the deadline. " <>
       expiry_note(:account_deletion),
     {"Confirm deletion", link},
     "If you did not request this, do not click the button — your account stays untouched. " <>
       "Consider changing your password if you suspect someone else has access to it."}
  end

  defp content(:account_deleted_template, _link) do
    {"Your account has been deleted — Tetrarchy Falls", "Your account has been deleted",
     "Your Tetrarchy Falls account and the personal data associated with it have been " <>
       "permanently deleted. Your game history now appears under an anonymous \"Erased\" " <>
       "name, no longer linked to you. Backup copies expire within 30 days.", nil,
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

  defp render_html(heading, intro, cta, outro) do
    """
    <div style="margin:0;padding:32px 16px;background-color:#f4f2ec;font-family:Verdana,Geneva,sans-serif;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;margin:0 auto;background-color:#ffffff;border:1px solid #e0dccf;border-top:4px solid #{@accent};">
        <tr>
          <td style="padding:32px 36px;">
            <p style="margin:0 0 4px 0;font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#{@accent};">Tetrarchy Falls</p>
            <h1 style="margin:0 0 16px 0;font-size:20px;color:#1c1a14;">#{heading}</h1>
            <p style="margin:0 0 24px 0;font-size:14px;line-height:1.6;color:#3d3a30;">#{intro}</p>
    #{cta_html(cta)}
            <p style="margin:0;font-size:12px;line-height:1.6;color:#6b675c;">#{outro}</p>
          </td>
        </tr>
        <tr>
          <td style="padding:16px 36px;border-top:1px solid #e0dccf;">
            <p style="margin:0;font-size:11px;color:#8a8577;">Tetrarchy Falls · <a href="https://tetrarchyfalls.com" style="color:#8a8577;">tetrarchyfalls.com</a></p>
          </td>
        </tr>
      </table>
    </div>
    """
  end

  defp cta_html(nil), do: ""

  defp cta_html({cta_label, cta_link}) do
    """
            <p style="margin:0 0 24px 0;">
              <a href="#{cta_link}" style="display:inline-block;padding:12px 28px;background-color:#{@accent};color:#ffffff;font-size:14px;text-decoration:none;">#{cta_label}</a>
            </p>
            <p style="margin:0 0 24px 0;font-size:12px;line-height:1.6;color:#6b675c;">Or paste this link into your browser:<br/><a href="#{cta_link}" style="color:#{@accent};word-break:break-all;">#{cta_link}</a></p>
    """
  end

  defp render_text(heading, intro, cta, outro) do
    """
    Tetrarchy Falls — #{heading}

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
