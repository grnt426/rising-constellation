defmodule RC.Accounts.InviteToken do
  @moduledoc """
  Stateless 24-hour invite tokens for account signup.

  Built on `Phoenix.Token.encrypt/4` -- authenticated encryption keyed off
  the endpoint's `secret_key_base`, with the expiration enforced at decode
  time. No DB row per token: the link IS the credential, and the same
  link can be redeemed by any number of new signups within the 24h window.

  Payload is just the referrer's account id. Because the token is encrypted
  (not just signed), the referrer id is not visible to anyone holding the
  link; only the server can decrypt it.

  Revocation: stateless tokens cannot be individually revoked. The
  `accounts.can_create_account_invites` flag is the mitigation -- flip it
  to false and the user can no longer mint new links. Outstanding links
  still work until they expire (worst case: 24h). To kill every outstanding
  token at once, rotate `secret_key_base`, which also invalidates all
  other Phoenix.Token-issued tokens.
  """

  @salt "account_invite"
  @max_age 86_400

  def encode(endpoint, referrer_id) when is_integer(referrer_id) do
    Phoenix.Token.encrypt(endpoint, @salt, %{ref: referrer_id})
  end

  def decode(endpoint, token) when is_binary(token) do
    case Phoenix.Token.decrypt(endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{ref: referrer_id}} when is_integer(referrer_id) ->
        {:ok, referrer_id}

      {:ok, _other} ->
        {:error, :invalid}

      {:error, :expired} = err ->
        err

      {:error, _reason} ->
        {:error, :invalid}
    end
  end

  def decode(_endpoint, _other), do: {:error, :invalid}
end
