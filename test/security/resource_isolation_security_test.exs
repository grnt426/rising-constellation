defmodule RC.Security.ResourceIsolationTest do
  @moduledoc """
  Regression tests for the Stage 2 resource-isolation fixes (all HIGH):

    * #4 — Folder IDOR: PUT/DELETE /scenarios/:sid/folders/:fid and
      /maps/:sid/folders/:fid moved to :own_resource_authorization with
      a new `:fid` plug clause.
    * #5 — Upload IDOR: DELETE /uploads/:upid moved out of the coarse
      blog-writer membership gate to per-upload ownership.
    * #6 — Blog post IDOR: PUT/DELETE /blog/posts/:bpid moved to
      :own_resource_authorization with a new `:bpid` plug clause.
    * #9 — Tutorial IDOR: GET /instances/tutorial/game/start/:pid moved
      to :own_resource_authorization so the existing `:pid` plug clause
      gates it.
  """
  use Portal.APIConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import RC.Fixtures
  import RC.ScenarioFixtures

  alias RC.Accounts.Profile
  alias RC.Blog
  alias RC.Repo
  alias RC.Scenarios
  alias RC.Scenarios.Folder

  describe "Stage 2 #4 — folders" do
    test "user A cannot PUT a scenario into user B's folder",
         %{conn: conn} do
      attacker = fixture(:user) |> activate!()
      victim = fixture(:user2) |> activate!()

      {:ok, victim_folder} =
        Scenarios.create_folder(%{name: "Victim's curation", description: "x"}, victim.id)

      scenario = scenario_fixture()

      response =
        conn
        |> login(attacker)
        |> put(Routes.folder_path(conn, :insert, scenario.id, victim_folder.id))

      assert response.status == 403,
             "expected 403; folder belongs to a different user"

      # Sanity: target folder is untouched.
      assert Repo.get!(Folder, victim_folder.id).account_id == victim.id
    end

    test "user A cannot DELETE a scenario from user B's folder",
         %{conn: conn} do
      attacker = fixture(:user) |> activate!()
      victim = fixture(:user2) |> activate!()

      {:ok, victim_folder} =
        Scenarios.create_folder(%{name: "Victim's curation", description: "x"}, victim.id)

      scenario = scenario_fixture()

      response =
        conn
        |> login(attacker)
        |> delete(Routes.folder_path(conn, :remove, scenario.id, victim_folder.id))

      assert response.status == 403
    end

    test "owner CAN insert into their own folder (positive case)",
         %{conn: conn} do
      owner = fixture(:user) |> activate!()
      {:ok, folder} = Scenarios.create_folder(%{name: "Mine", description: "x"}, owner.id)

      scenario = scenario_fixture()

      response =
        conn
        |> login(owner)
        |> put(Routes.folder_path(conn, :insert, scenario.id, folder.id))

      assert response.status in [200, 201], "owner must still be able to use their own folder"
    end
  end

  describe "Stage 2 #5 — uploads" do
    setup [:create_group]

    test "non-admin non-owner gets 403 on DELETE /uploads/:upid",
         %{conn: conn, user_author: writer_a} do
      writer_a = activate!(writer_a)

      # We don't actually seed an Upload row — the Uploads schema requires
      # a real attached file (NOT NULL `:file` column populated by
      # cast_attachments). That's not the property under test here.
      #
      # Authorization runs BEFORE the controller / DB. For a non-existent
      # upload, `Uploader.own_upload?/2` returns false (Repo.exists? = false)
      # and writer_a isn't admin, so Plug.Authorization.validate returns
      # false → 403. The plug never lets the request reach the controller.
      # That IS the security property: blog-writer membership alone no
      # longer grants the ability to mutate someone else's upload.
      fake_upload_id = 9_999_999

      response =
        conn
        |> login(writer_a)
        |> delete(Routes.upload_path(conn, :delete, fake_upload_id))

      assert response.status == 403,
             "expected 403; blog-writer membership must not bypass per-upload ownership"
    end

    test "admin DOES bypass (admin? short-circuit preserved)",
         %{conn: conn, admin: admin} do
      admin = activate!(admin)

      # Same fake-id setup. Admin should pass the plug; controller then
      # 404s since the upload doesn't exist. The point is the plug DIDN'T 403.
      response =
        conn
        |> login(admin)
        |> delete(Routes.upload_path(conn, :delete, 9_999_998))

      refute response.status == 403,
             "admin must not be rejected by :own_resource_authorization"
    end
  end

  describe "Stage 2 #6 — blog posts" do
    setup [:create_group]

    test "blog-writer A cannot PUT blog-writer B's post",
         %{conn: conn, user_author: writer_a} do
      writer_a = activate!(writer_a)
      other_writer = fixture(:user3) |> activate!()
      group = Repo.one!(from(g in RC.Groups.Group, where: g.name == "blog-writers"))
      {:ok, _} = RC.Groups.insert_accounts(group, [other_writer.id])

      category = category_fixture()

      {:ok, victim_post} =
        Blog.create_post(
          %{
            title: "victim's article",
            picture: "x",
            content_raw: "body",
            summary_raw: "summary",
            language: "en",
            category_id: category.id
          },
          other_writer.id
        )

      response =
        conn
        |> login(writer_a)
        |> put(
          Routes.post_path(conn, :update, victim_post.id),
          %{"post" => %{"title" => "defaced"}}
        )

      assert response.status == 403

      reloaded = Blog.get_post(victim_post.id)
      assert reloaded.title == "victim's article", "post content must be unchanged"
    end

    test "blog-writer A cannot DELETE blog-writer B's post",
         %{conn: conn, user_author: writer_a} do
      writer_a = activate!(writer_a)
      other_writer = fixture(:user3) |> activate!()
      group = Repo.one!(from(g in RC.Groups.Group, where: g.name == "blog-writers"))
      {:ok, _} = RC.Groups.insert_accounts(group, [other_writer.id])

      category = category_fixture()

      {:ok, victim_post} =
        Blog.create_post(
          %{
            title: "victim's article",
            picture: "x",
            content_raw: "body",
            summary_raw: "summary",
            language: "en",
            category_id: category.id
          },
          other_writer.id
        )

      response =
        conn
        |> login(writer_a)
        |> delete(Routes.post_path(conn, :delete, victim_post.id))

      assert response.status == 403
      assert Blog.get_post(victim_post.id) != nil
    end
  end

  describe "Stage 2 #9 — tutorial creation" do
    test "user A cannot create a tutorial bound to user B's profile",
         %{conn: conn} do
      attacker = fixture(:user) |> activate!()
      victim = fixture(:user2) |> activate!()

      {:ok, victim_profile} =
        Repo.insert(
          Profile.changeset(%Profile{}, %{
            avatar: "x",
            name: "victim profile",
            account_id: victim.id
          })
        )

      response =
        conn
        |> login(attacker)
        |> get(Routes.game_path(conn, :create_and_join_tutorial, victim_profile.id))

      assert response.status == 403,
             "expected 403; attacker doesn't own the supplied profile"
    end
  end

  defp activate!(account) do
    {:ok, a} = Ecto.Changeset.change(account, status: :active) |> Repo.update()
    a
  end
end
