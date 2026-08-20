defmodule RC.PlayerEventsTest do
  @moduledoc """
  Scoping guarantees for the in-game Reports panel. The read/delete helpers
  are reachable from the player channel, so they MUST only ever touch the
  caller's own personal (registration-scoped) box events — never another
  player's reports, a shared faction/global row, or transient text pings.
  """
  use Portal.APIConnCase, async: false

  import RC.Fixtures
  import RC.ScenarioFixtures

  alias RC.Accounts.Profile
  alias RC.Instances.PlayerEvent
  alias RC.PlayerEvents
  alias RC.Registrations
  alias RC.Repo

  setup do
    %{instance: instance} = instance_fixture()
    owner = fixture(:user)

    Machinery.transition_to(
      Map.put(instance, :account_id, owner.id),
      RC.Instances.InstanceStateMachine,
      "open"
    )

    [faction | _] = instance.factions

    {:ok, profile_a} =
      Repo.insert(Profile.changeset(%Profile{}, %{avatar: "x", name: "A", account_id: owner.id}))

    {:ok, profile_b} =
      Repo.insert(Profile.changeset(%Profile{}, %{avatar: "x", name: "B", account_id: fixture(:user2).id}))

    {:ok, %{registration: reg_a}} = Registrations.register_profile(faction, profile_a)
    {:ok, %{registration: reg_b}} = Registrations.register_profile(faction, profile_b)

    {:ok, instance: instance, reg_a: reg_a, reg_b: reg_b}
  end

  defp insert_event(instance_id, attrs) do
    {:ok, event} =
      %PlayerEvent{}
      |> PlayerEvent.changeset(Map.merge(%{type: "box", key: "raid", data: "{}", instance_id: instance_id}, attrs))
      |> Repo.insert()

    event
  end

  # is_read isn't a cast field (set only via the read helpers in prod), so
  # seed it directly here.
  defp mark_read!(event), do: Repo.update!(Ecto.Changeset.change(event, is_read: true))

  test "get_for_registration returns only the caller's own box events", ctx do
    own = insert_event(ctx.instance.id, %{registration_id: ctx.reg_a.id})
    insert_event(ctx.instance.id, %{registration_id: ctx.reg_a.id, type: "text", key: "raid_started"})
    insert_event(ctx.instance.id, %{registration_id: ctx.reg_b.id})

    insert_event(ctx.instance.id, %{
      registration_id: nil,
      faction_id: ctx.reg_a.faction_id,
      type: "faction",
      key: "new_player"
    })

    ids = ctx.reg_a.id |> PlayerEvents.get_for_registration() |> Map.fetch!(:entries) |> Enum.map(& &1.id)

    assert ids == [own.id]
  end

  test "mark_all_read marks only the caller's own box events", ctx do
    mine = insert_event(ctx.instance.id, %{registration_id: ctx.reg_a.id})
    theirs = insert_event(ctx.instance.id, %{registration_id: ctx.reg_b.id})

    assert {1, _} = PlayerEvents.mark_all_read(ctx.reg_a.id)
    assert Repo.get(PlayerEvent, mine.id).is_read
    refute Repo.get(PlayerEvent, theirs.id).is_read
  end

  test "delete_read removes only the caller's own read box events", ctx do
    read_mine = ctx.instance.id |> insert_event(%{registration_id: ctx.reg_a.id}) |> mark_read!()
    unread_mine = insert_event(ctx.instance.id, %{registration_id: ctx.reg_a.id})
    read_theirs = ctx.instance.id |> insert_event(%{registration_id: ctx.reg_b.id}) |> mark_read!()

    assert {1, _} = PlayerEvents.delete_read(ctx.reg_a.id)
    refute Repo.get(PlayerEvent, read_mine.id)
    assert Repo.get(PlayerEvent, unread_mine.id)
    assert Repo.get(PlayerEvent, read_theirs.id)
  end

  test "delete_all removes the caller's box events but spares text + other players", ctx do
    box_mine = insert_event(ctx.instance.id, %{registration_id: ctx.reg_a.id})
    text_mine = insert_event(ctx.instance.id, %{registration_id: ctx.reg_a.id, type: "text", key: "raid_started"})
    box_theirs = insert_event(ctx.instance.id, %{registration_id: ctx.reg_b.id})

    assert {1, _} = PlayerEvents.delete_all(ctx.reg_a.id)
    refute Repo.get(PlayerEvent, box_mine.id)
    assert Repo.get(PlayerEvent, text_mine.id)
    assert Repo.get(PlayerEvent, box_theirs.id)
  end
end
