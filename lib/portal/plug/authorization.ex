defmodule Portal.Plug.Authorization do
  require Logger

  alias RC.Groups
  alias RC.Messenger
  alias RC.Blog
  alias RC.Accounts
  alias RC.Instances
  alias RC.Scenarios
  alias RC.Uploader
  alias Portal.Plug.AuthErrorHandler

  def init(options), do: options

  def call(%{private: private} = conn, atom) do
    if Map.has_key?(private, :guardian_default_resource) do
      validate(conn, atom)
    else
      http_error(conn, 401)
    end
  end

  def validate(conn, :admin) do
    case admin?(conn) do
      true -> conn
      _ -> http_error(conn, 403)
    end
  end

  def validate(conn, :own_resource) do
    case admin?(conn) or own_resource?(conn) do
      true -> conn
      _ -> http_error(conn, 403)
    end
  end

  def validate(conn, :group_resource) do
    case admin?(conn) or group_resource?(conn) do
      true -> conn
      _ -> http_error(conn, 403)
    end
  end

  def validate(conn, :conversation_admin) do
    case admin?(conn) or conversation_admin?(conn) do
      true -> conn
      _ -> http_error(conn, 403)
    end
  end

  def validate(conn, :conversation_member) do
    case admin?(conn) or conversation_member?(conn) do
      true -> conn
      _ -> http_error(conn, 403)
    end
  end

  def validate(conn, _atom) do
    http_error(conn, 403)
  end

  defp admin?(conn) do
    conn.private.guardian_default_resource.role == :admin
  end

  # IMPORTANT: every clause below dispatches on `path_params` (only the keys
  # bound by the route's URL pattern), NOT `conn.params`. `conn.params`
  # merges body + query-string + path, so reading from it lets an attacker
  # inject a key like `?pid=<own>` to flip a route's gate from one resource
  # type to another and pass an ownership check against their own resource.
  # Path-params-only binds the dispatch to the route exactly as declared.

  defp own_resource?(%{path_params: %{"aid" => id}} = conn) do
    with true <- is_binary(id),
         {id, ""} <- Integer.parse(id) do
      conn.private.guardian_default_resource.id == id
    else
      _ -> false
    end
  end

  # for blog comments
  defp own_resource?(%{path_params: %{"bcid" => blog_comment_id}} = conn) do
    account_id = conn.private.guardian_default_resource.id

    Blog.own_comment?(account_id, blog_comment_id)
  end

  # for profiles
  defp own_resource?(%{path_params: %{"pid" => profile_id}} = conn) do
    account_id = conn.private.guardian_default_resource.id

    Accounts.own_profile?(account_id, profile_id)
  end

  # for instances actions
  defp own_resource?(%{path_params: %{"iid" => instance_id}} = conn) do
    account_id = conn.private.guardian_default_resource.id

    Instances.own_instance?(account_id, instance_id)
  end

  # for folder mutations (PUT/DELETE /scenarios/:sid/folders/:fid etc.)
  defp own_resource?(%{path_params: %{"fid" => folder_id}} = conn) do
    account_id = conn.private.guardian_default_resource.id

    Scenarios.own_folder?(account_id, folder_id)
  end

  # for map mutations (PUT/DELETE /api/maps/:mid). Forge Stage 2: maps are
  # now community-authored. Author owns their map; admins can touch any
  # map; engine-seeded "Official" rows (author_id IS NULL) are admin-only.
  #
  # The PUT/DELETE /api/maps/:mid/folders/:fid clause above (with `fid`)
  # wins first because the more-specific path param binds the dispatch —
  # this clause only fires when the route exposes just `mid` (the map
  # itself, not folder membership).
  defp own_resource?(%{path_params: %{"mid" => map_id}} = conn) do
    account_id = conn.private.guardian_default_resource.id

    Scenarios.own_map?(account_id, map_id)
  end

  # for scenario mutations (PUT/DELETE /api/scenarios/:sid). Same shape
  # as own map?, see the rationale above.
  defp own_resource?(%{path_params: %{"sid" => scenario_id}} = conn) do
    account_id = conn.private.guardian_default_resource.id

    Scenarios.own_scenario?(account_id, scenario_id)
  end

  # for upload deletion (DELETE /uploads/:upid)
  defp own_resource?(%{path_params: %{"upid" => upload_id}} = conn) do
    account_id = conn.private.guardian_default_resource.id

    Uploader.own_upload?(account_id, upload_id)
  end

  # for blog-post mutations (PUT/DELETE /blog/posts/:bpid)
  defp own_resource?(%{path_params: %{"bpid" => post_id}} = conn) do
    account_id = conn.private.guardian_default_resource.id

    Blog.own_post?(account_id, post_id)
  end

  # Default deny if the route's path carries no recognized resource key.
  defp own_resource?(_conn), do: false

  defp group_resource?(%{path_params: %{"iid" => instance_id}} = conn) do
    account_id = conn.private.guardian_default_resource.id

    if Groups.instance_in_group?(instance_id) do
      Groups.instance_access?(account_id, instance_id)
    else
      true
    end
  end

  defp group_resource?(conn) do
    account_id = conn.private.guardian_default_resource.id

    Groups.blog_author?(account_id)
  end

  defp conversation_member?(%{path_params: %{"pid" => profile_id, "cid" => conversation_id}} = conn) do
    account_id = conn.private.guardian_default_resource.id

    Messenger.conversation_member?(conversation_id, account_id, profile_id)
  end

  defp conversation_member?(_conn), do: false

  defp conversation_admin?(%{path_params: %{"cid" => conversation_id, "pid" => profile_id}} = conn) do
    account_id = conn.private.guardian_default_resource.id

    Messenger.conversation_admin?(conversation_id, account_id, profile_id)
  end

  defp conversation_admin?(_conn), do: false

  defp http_error(conn, code) do
    case code do
      403 -> AuthErrorHandler.auth_error(conn, {:forbidden, ""}, %{})
      401 -> AuthErrorHandler.auth_error(conn, {:unauthorized, ""}, %{})
    end
  end
end
