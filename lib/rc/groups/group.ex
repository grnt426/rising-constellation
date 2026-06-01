defmodule RC.Groups.Group do
  use Ecto.Schema
  alias RC.Accounts.Account
  alias RC.Instances.Instance
  import Ecto.Changeset

  schema "groups" do
    field(:name, :string)
    many_to_many(:accounts, Account, join_through: "account_groups", on_delete: :delete_all, on_replace: :delete)
    many_to_many(:instances, Instance, join_through: "instance_groups", on_delete: :delete_all, on_replace: :delete)

    timestamps(type: :utc_datetime_usec)
  end

  # Stage 6 Cluster C fix.
  #
  # The previous changeset chained `cast_assoc(:accounts)` and
  # `cast_assoc(:instances)` with no `with:` callback, so Ecto used the
  # default `Account.changeset/2` and `Instance.changeset/2`. An admin
  # POSTing `/api/groups {"group": {"accounts": [{"email": "...",
  # "role": "admin", "password": "..."}]}}` would silently mass-insert
  # a fresh admin account through the full Account.changeset, bypassing
  # the signup transaction and any email verification. Update path was
  # worse — `on_replace: :delete` on the many_to_many silently dropped
  # every other membership.
  #
  # Membership management goes through `RC.Groups.insert_accounts/2`
  # and `RC.Groups.insert_instances/2`, which build per-row
  # `AccountGroup.changeset` / `InstanceGroup.changeset` rows that only
  # cast `:account_id` / `:group_id`. The bulk endpoints
  # (POST /api/groups/:gid/account and similar) use those helpers
  # directly. Group.changeset/2 only touches the group's own name.
  @doc false
  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, max: 120)
    |> validate_exclusion(:name, blocklist())
  end

  def changeset_update(group, objects, type) do
    group
    |> cast(%{}, [:name])
    |> validate_exclusion(:name, blocklist())
    # associate projects to the user
    |> put_assoc(type, objects)
  end

  defp blocklist do
    Application.get_env(:rc, RC.Groups) |> Keyword.get(:reserved_names)
  end
end
