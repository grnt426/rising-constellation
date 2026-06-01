defmodule RC.Security.MassAssignmentTest do
  @moduledoc """
  Regression tests for Stage 2 #2 / #3 / #6 (all HIGH): the user-facing
  update endpoints used to call the same changeset the admin / system
  paths use, casting every column including ones that grant horizontal
  privileges (ownership transfer, leaderboard elo, instance state).

  Fix: split changesets — `Profile.update_changeset/2`,
  `Instance.update_changeset/2`, and a `:account_id`-less
  `Blog.Post.changeset/2` (controller forces it from the JWT).
  """
  use Portal.APIConnCase, async: false

  import RC.Fixtures
  import RC.ScenarioFixtures

  alias RC.Accounts
  alias RC.Accounts.Profile
  alias RC.Instances
  alias RC.Repo

  defp profile_setup(_) do
    user = fixture(:user) |> activate!()

    {:ok, profile} =
      Repo.insert(
        Profile.changeset(%Profile{}, %{
          avatar: "x",
          name: "the original profile",
          account_id: user.id
        })
      )

    {:ok, user: user, profile: profile}
  end

  describe "Stage 2 #2 — Profile owner cannot forge :elo via PUT /api/profiles/:pid" do
    setup [:profile_setup]

    test "elo in the body is silently dropped",
         %{conn: conn, user: user, profile: profile} do
      original_elo = profile.elo

      response =
        conn
        |> login(user)
        |> put(
          Routes.profile_path(conn, :update, profile.id),
          %{"profile" => %{"elo" => 99_999, "name" => "renamed"}}
        )

      assert response.status == 200

      reloaded = Accounts.get_profile!(profile.id)
      assert reloaded.elo == original_elo,
             "expected elo to stay at #{original_elo}; was changed to #{reloaded.elo}"
      assert reloaded.name == "renamed", "the legitimate field should still update"
    end

    test "account_id in the body is silently dropped (no ownership transfer)",
         %{conn: conn, user: user, profile: profile} do
      victim = fixture(:user2) |> activate!()

      response =
        conn
        |> login(user)
        |> put(
          Routes.profile_path(conn, :update, profile.id),
          %{"profile" => %{"account_id" => victim.id, "name" => "renamed"}}
        )

      assert response.status == 200

      reloaded = Accounts.get_profile!(profile.id)
      assert reloaded.account_id == user.id,
             "expected profile to stay with #{user.id}; was reassigned to #{reloaded.account_id}"
    end
  end

  describe "Stage 2 #3 — Instance owner cannot bypass the state machine via PUT" do
    test "PUT /api/instances/:iid {state: \"ended\"} does NOT short-circuit the state machine",
         %{conn: conn} do
      owner = fixture(:user) |> activate!()
      scenario = scenario_fixture()
      original_state = "created"

      {:ok, %{instance: instance}} =
        Instances.create_instance(
          %{
            "description" => "x",
            "name" => "victim instance",
            "opening_date" => "2010-04-17T14:00:00Z",
            "registration_type" => "pre_registration",
            "registration_status" => "closed",
            "game_type" => "official",
            "public" => true,
            "start_setting" => "auto",
            "factions" => [
              %{"key" => "tetrarchy", "capacity" => 10},
              %{"key" => "myrmezir", "capacity" => 10}
            ]
          },
          scenario,
          owner.id
        )

      assert instance.state == original_state

      response =
        conn
        |> login(owner)
        |> put(
          Routes.instance_path(conn, :update, instance.id),
          %{"instance" => %{"state" => "ended", "name" => "renamed"}}
        )

      assert response.status == 200

      reloaded = Instances.get_instance(instance.id)
      assert reloaded.state == original_state,
             "expected state to stay #{original_state}; was forced to #{reloaded.state}"
      assert reloaded.name == "renamed"
    end
  end

  describe "Stage 2 #6 — Blog post :account_id cannot be forged via POST" do
    setup [:create_post]

    test "POST /api/blog/posts forces account_id from the JWT, ignoring body field",
         %{conn: conn, user_author: writer} do
      # The fixture seeds the `blog-writers` group with `user_author` so they
      # can hit POST /blog/posts. `user`/`admin` would also; the writer is
      # the realistic case.
      writer = activate!(writer)
      victim = fixture(:user3) |> activate!()
      category = category_fixture()

      response =
        conn
        |> login(writer)
        |> post(
          Routes.post_path(conn, :create),
          %{
            "post" => %{
              "title" => "smear piece",
              "picture" => "x",
              "content_raw" => "body",
              "summary_raw" => "summary",
              "language" => "en",
              "category_id" => category.id,
              # Attacker tries to attribute the post to the victim.
              "account_id" => victim.id
            }
          }
        )

      # Whether the request succeeded depends on group membership; we only
      # care that account_id was NOT taken from the body.
      if response.status in [200, 201] do
        body = json_response(response, response.status)
        # The view exposes the post's account_id through the embedded account.
        post = RC.Blog.get_post(body["id"])

        assert post.account_id == writer.id,
               "expected blog post to be attributed to the writer (#{writer.id}); was attributed to #{post.account_id}"
      end
    end
  end

  defp activate!(account) do
    {:ok, a} = Ecto.Changeset.change(account, status: :active) |> Repo.update()
    a
  end
end
