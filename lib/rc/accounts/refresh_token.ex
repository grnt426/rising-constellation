defmodule RC.Accounts.RefreshToken do
  @moduledoc """
  Rotation state for one issued refresh JWT, keyed by its "jti" claim.

  `rotated_at` NULL = this token is the current credential of its `family`
  (a UUID minted at login and carried through every rotation as the "fam"
  claim). Redeeming a token stamps `rotated_at` and issues a successor in
  the same family; re-presenting a stamped token after the grace window is
  treated as replay/theft — see `RC.Accounts.redeem_refresh_token/3`.

  The JWT itself stays the credential (exp + "tv" are still enforced by
  `RC.Guardian`); this table only adds single-use semantics on top.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:jti, :string, autogenerate: false}
  schema "refresh_tokens" do
    field(:family, :string)
    field(:rotated_at, :utc_datetime)
    field(:expires_at, :utc_datetime)

    belongs_to(:account, RC.Accounts.Account)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(refresh_token, attrs) do
    refresh_token
    |> cast(attrs, [:jti, :account_id, :family, :rotated_at, :expires_at])
    |> validate_required([:jti, :account_id, :family, :expires_at])
    |> foreign_key_constraint(:account_id)
    |> unique_constraint(:jti, name: :refresh_tokens_pkey)
  end
end
