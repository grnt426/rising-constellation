defmodule Portal.WaveRegistrationLockTest do
  @moduledoc """
  Wave Defense: the bot-held faction must refuse human registrations through
  the real lobby endpoint, while the human faction — and the same faction in
  any non-wave game — stays joinable.
  """
  use Portal.APIConnCase
  import RC.Fixtures
  import RC.ScenarioFixtures

  alias RC.Accounts.Profile
  alias RC.Repo

  setup %{conn: conn} do
    %{instance: instance} = instance_fixture()
    {:ok, account: account} = create_account_user(%{})

    Machinery.transition_to(instance |> Map.put(:account_id, account.id), RC.Instances.InstanceStateMachine, "open")

    {:ok, profile} =
      Repo.insert(Profile.changeset(%Profile{}, %{avatar: "TODO", name: account.name, account_id: account.id}))

    [human_faction, bot_faction] = instance.factions

    {:ok,
     conn: put_req_header(conn, "accept", "application/json"),
     instance: instance,
     account: account,
     profile: profile,
     human_faction: human_faction,
     bot_faction: bot_faction}
  end

  test "a human cannot join the bot faction of a wave game", ctx do
    make_wave(ctx.instance, ctx.bot_faction)

    conn = join(ctx, ctx.bot_faction)

    assert json_response(conn, 403)["message"] == "bot_faction_locked"
  end

  test "a human can still join the human faction of a wave game", ctx do
    make_wave(ctx.instance, ctx.bot_faction)

    conn = join(ctx, ctx.human_faction)

    assert json_response(conn, 200)["message"] == "registered"
  end

  test "the same faction stays joinable outside wave games", ctx do
    conn = join(ctx, ctx.bot_faction)

    assert json_response(conn, 200)["message"] == "registered"
  end

  defp make_wave(instance, bot_faction) do
    instance
    |> Ecto.Changeset.change(game_data: %{"game_mode_type" => "wave", "wave" => %{"bot_faction" => bot_faction.faction_ref}})
    |> Repo.update!()
  end

  defp join(ctx, faction) do
    ctx.conn
    |> login(ctx.account)
    |> post(Routes.registration_path(ctx.conn, :join, ctx.profile.id), %{
      instance_id: ctx.instance.id,
      faction_id: faction.id
    })
  end
end
