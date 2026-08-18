defmodule Portal.FightControllerTest do
  use Portal.APIConnCase

  import RC.Fixtures

  @attacker %{
    "tiles" => [
      %{"ship_key" => "fighter_1", "level" => 0},
      %{"ship_key" => "fighter_1", "level" => 0},
      %{"ship_key" => "corvette_1", "level" => 2},
      nil,
      nil,
      nil
    ]
  }

  @defender %{
    "tiles" => [
      %{"ship_key" => "fighter_2", "level" => 0},
      %{"ship_key" => "corvette_2", "level" => 0},
      nil,
      nil,
      nil,
      nil
    ]
  }

  setup %{conn: conn} do
    {:ok, conn: login(conn, fixture(:user))}
  end

  defp run_fight(conn, extra \\ %{}) do
    body = Map.merge(%{"attacker" => @attacker, "defender" => @defender}, extra)
    post(conn, "/api/run-fight", body)
  end

  describe "run (single)" do
    test "keeps the legacy single-run response shape", %{conn: conn} do
      body = json_response(run_fight(conn), 200)

      assert %{"initial" => _, "final" => _, "logs" => logs, "metadata" => _} = body
      assert is_list(logs) and logs != []
      refute Map.has_key?(body, "runs")
    end
  end

  describe "run (multi)" do
    test "aggregates n battles with consistent counts", %{conn: conn} do
      body = json_response(run_fight(conn, %{"runs" => 30}), 200)

      runs = body["runs"]
      assert runs["n"] == 30
      assert runs["attacker_wins"] + runs["defender_wins"] + runs["draws"] == 30

      # The example battle is a full single-run payload alongside the aggregate.
      assert is_list(body["logs"]) and body["logs"] != []
      assert [%{"army" => _}] = body["final"]["attackers"]

      # One aggregate entry per filled tile, aligned by tile id, with sane
      # survival counts and survivor-only hull quantiles.
      [att_side] = runs["sides"]["attackers"]
      assert att_side["character"] == 1
      assert length(att_side["tiles"]) == 3

      Enum.each(att_side["tiles"], fn tile ->
        assert tile["survived"] in 0..30

        case tile["hull"] do
          nil ->
            assert tile["survived"] == 0

          %{"p10" => p10, "p50" => p50, "p90" => p90} ->
            assert tile["survived"] > 0
            assert p10 <= p50 and p50 <= p90
            assert p10 >= 0.0 and p90 <= 1.0
        end
      end)

      [def_side] = runs["sides"]["defenders"]
      assert def_side["character"] == 2
      assert length(def_side["tiles"]) == 2

      # Ships-lost quantiles are counts within the fleet size.
      losses = runs["losses"]["attackers"]
      assert losses["p10"] <= losses["p50"]
      assert losses["p50"] <= losses["p90"]
      assert losses["p90"] <= losses["max"]
      assert losses["max"] in 0..3
    end

    test "the same setup returns the identical distribution", %{conn: conn} do
      first = json_response(run_fight(conn, %{"runs" => 20}), 200)
      second = json_response(run_fight(conn, %{"runs" => 20}), 200)

      # Whole-body equality doesn't hold: character first/last names come from
      # the deliberately unseeded cosmetic Picker path (Data.Picker.random/2
      # for virtual instances) and are never shown by the simulator. The
      # product guarantee is the distribution and the example battle.
      assert first["runs"] == second["runs"]
      assert first["logs"] == second["logs"]
      assert first["metadata"] == second["metadata"]
    end

    test "runs is capped at 100 and floored at 1", %{conn: conn} do
      body = json_response(run_fight(conn, %{"runs" => 5000}), 200)
      assert body["runs"]["n"] == 100

      body = json_response(run_fight(conn, %{"runs" => 0}), 200)
      refute Map.has_key?(body, "runs")
    end
  end
end
