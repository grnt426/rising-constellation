defmodule RC.AccountsEmailsTest do
  # async: false — the configuration-set test mutates the global mailer
  # config for its duration.
  use ExUnit.Case, async: false

  alias RC.Accounts.Account
  alias RC.Accounts.AccountToken
  alias RC.Accounts.Emails

  @account %Account{name: "Tetrarch Prime", email: "prime@example.com"}
  @token %AccountToken{value: "tok-123-abc", candidate_email: "new@example.com"}

  test "verification email goes to the account address with the registration link" do
    email = Emails.build(:verification_template, @account, @token)

    assert email.to == [{"Tetrarch Prime", "prime@example.com"}]
    assert email.subject =~ "Confirm your email"
    assert email.html_body =~ "login/?action=validate-registration&token=tok-123-abc"
    assert email.text_body =~ "login/?action=validate-registration&token=tok-123-abc"
  end

  test "password reset email carries the reset link" do
    email = Emails.build(:password_reset_template, @account, @token)

    assert email.to == [{"Tetrarch Prime", "prime@example.com"}]
    assert email.subject =~ "Reset your password"
    assert email.html_body =~ "reset-password/?token=tok-123-abc"
    assert email.text_body =~ "reset-password/?token=tok-123-abc"
  end

  test "email update goes to the candidate address with the email-update link" do
    email = Emails.build(:email_update_template, @account, @token)

    assert email.to == [{"Tetrarch Prime", "new@example.com"}]
    assert email.html_body =~ "login/?action=validate-email-update&token=tok-123-abc"
  end

  test "web bind goes to the candidate address with the bind link" do
    email = Emails.build(:web_bind_template, @account, @token)

    assert email.to == [{"Tetrarch Prime", "new@example.com"}]
    assert email.html_body =~ "bind/?token=tok-123-abc"
  end

  test "sender comes from the mailer config" do
    {_name, address} = Application.get_env(:rc, RC.Mailer) |> Keyword.get(:sender)
    email = Emails.build(:verification_template, @account, @token)

    assert {_, ^address} = email.from
  end

  test "configuration set is attached as a provider option only when configured" do
    email = Emails.build(:verification_template, @account, @token)
    refute Map.has_key?(email.provider_options, :configuration_set_name)

    original = Application.get_env(:rc, RC.Mailer)
    Application.put_env(:rc, RC.Mailer, Keyword.put(original, :configuration_set, "rc-transactional"))
    on_exit(fn -> Application.put_env(:rc, RC.Mailer, original) end)

    email = Emails.build(:verification_template, @account, @token)
    assert email.provider_options[:configuration_set_name] == "rc-transactional"
  end
end
