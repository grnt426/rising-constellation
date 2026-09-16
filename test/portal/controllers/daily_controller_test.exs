defmodule Portal.DailyControllerTest do
  use Portal.APIConnCase

  import RC.Fixtures

  setup %{conn: conn} do
    {:ok, conn: login(conn, fixture(:user))}
  end

  test "GET /api/daily/today returns the day's preview", %{conn: conn} do
    body = json_response(get(conn, "/api/daily/today"), 200)

    assert is_binary(body["date"])
    assert is_binary(body["objective"]["description"])
    assert is_list(body["mutators"])
    assert is_binary(body["system"]["archetype"])
  end

  # Regression: sector-day objectives generate six systems, and the preview
  # used to pattern-match exactly one — a 500 that left the daily page with no
  # objective or mutators at all (2026-09-16).
  test "the preview builds for multi-system days" do
    definitions =
      for offset <- 0..120 do
        Daily.definition_for(Date.add(~D[2026-09-01], offset))
      end

    multi = Enum.filter(definitions, &(length(&1.game_data["systems"]) > 1))
    assert multi != [], "no multi-system day in the sampled range"

    for definition <- multi do
      view = Portal.DailyController.preview_view(definition)
      assert view.system.archetype == hd(definition.game_data["systems"])["type"]
      assert view.objective.description
    end
  end
end
