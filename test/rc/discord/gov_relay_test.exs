defmodule RC.Discord.GovRelayTest do
  @moduledoc """
  Pure-renderer tests for the faction-government Discord relay. The
  GenServer itself never runs here — `render/2` is a pure function of
  (faction_key, event), and the forwarding whitelist is data.
  """

  use ExUnit.Case, async: true

  alias RC.Discord.GovRelay

  describe "render/2 — election lifecycle" do
    test "elections opening list the leadership seats" do
      line =
        GovRelay.render(:cardan, %{
          type: :elections_opened,
          seats: [:leader, :economy, :military],
          renewal: false
        })

      assert line =~ "Elections have opened for Cardan"
      assert line =~ "Leader"
      assert line =~ "Head of Economy"
      assert line =~ "Head of Military"
    end

    test "elections opening for non-leadership seats stay silent" do
      assert GovRelay.render(:myrmezir, %{type: :elections_opened, seats: [:laws], renewal: true}) ==
               nil
    end

    test "a seated player announces with the decorated display name" do
      event = %{
        type: :seat_changed,
        seat: :leader,
        player_id: 7,
        name: "Nova",
        who_display: "Nova (Discord: kurtz)"
      }

      assert GovRelay.render(:ark, event) ==
               "Nova (Discord: kurtz) is now the Leader of A.R.K. <:ark:1521144064374739145>."
    end

    test "a seated player without a Discord link falls back to the in-game name" do
      event = %{type: :seat_changed, seat: :economy, player_id: 7, name: "Nova"}
      assert GovRelay.render(:ark, event) =~ "Nova is now the Head of Economy"
    end

    test "vacated seats do not post on their own" do
      assert GovRelay.render(:ark, %{type: :seat_changed, seat: :leader, player_id: nil, name: nil}) ==
               nil
    end

    test "failed elections broadcast that the seat stays open" do
      line = GovRelay.render(:cardan, %{type: :election_failed, seat: :leader, reason: :no_votes})
      assert line =~ "Leader election for Cardan"
      assert line =~ "failed"
      assert line =~ "stays open"
    end
  end

  describe "render/2 — ceremony events" do
    test "depositions, dissolutions, and challenges have copy" do
      assert GovRelay.render(:tetrarchy, %{type: :deposition_started, seat: :leader, by: 1}) =~
               "vote to depose the Leader of Tetrarchy"

      assert GovRelay.render(:tetrarchy, %{type: :deposed, seat: :leader, name: "Nova", player_id: 1}) =~
               "Nova has been deposed"

      assert GovRelay.render(:synelle, %{type: :government_dissolved, reason: :strikes}) =~
               "government of Synelectic Federation"

      assert GovRelay.render(:synelle, %{type: :cabinet_dissolved}) =~ "cabinet of"
      assert GovRelay.render(:synelle, %{type: :crisis_vote_started}) =~ "crisis vote"

      assert GovRelay.render(:ark, %{type: :challenge_started, name: "Nova", stake: 500}) =~
               "challenge for the leadership"

      assert GovRelay.render(:ark, %{type: :challenge_defended, name: "Nova"}) =~
               "defended its position"

      assert GovRelay.render(:ark, %{type: :government_overthrown, name: "Nova"}) =~
               "has overthrown the government"
    end

    test "incapacitated holders broadcast the vacancy" do
      line =
        GovRelay.render(:cardan, %{
          type: :seat_incapacitated,
          seat: :military,
          name: "Nova",
          player_id: 3,
          reason: :afk
        })

      assert line =~ "Nova no longer holds the Head of Military seat"
    end
  end

  describe "render/2 — hygiene and scope" do
    test "treasury and policy events never broadcast" do
      assert GovRelay.render(:ark, %{type: :patent_purchased, key: :x, cost: 1, by: 1}) == nil
      assert GovRelay.render(:ark, %{type: :lex_purchased, key: :x, cost: 1, by: 1}) == nil
      assert GovRelay.render(:ark, %{type: :taxes_changed, rates: %{}, by: 1}) == nil
      assert GovRelay.render(:ark, %{type: :laws_changed, laws: [], by: 1}) == nil
      assert GovRelay.render(:ark, %{type: :sync_effects}) == nil
    end

    test "the forwarding whitelist excludes economy churn" do
      refute :patent_purchased in GovRelay.ceremony_events()
      refute :lex_purchased in GovRelay.ceremony_events()
      refute :taxes_changed in GovRelay.ceremony_events()
      refute :laws_changed in GovRelay.ceremony_events()

      assert :elections_opened in GovRelay.ceremony_events()
      assert :seat_changed in GovRelay.ceremony_events()
      assert :election_failed in GovRelay.ceremony_events()
    end

    test "no em-dashes in any ceremony copy" do
      events = [
        %{type: :elections_opened, seats: [:leader], renewal: false},
        %{type: :seat_changed, seat: :leader, player_id: 1, name: "Nova"},
        %{type: :election_failed, seat: :leader, reason: :no_votes},
        %{type: :deposition_started, seat: :leader, by: 1},
        %{type: :deposed, seat: :leader, name: "Nova", player_id: 1},
        %{type: :government_dissolved, reason: :strikes},
        %{type: :cabinet_dissolved},
        %{type: :crisis_vote_started},
        %{type: :challenge_started, name: "Nova", stake: 1},
        %{type: :challenge_defended, name: "Nova"},
        %{type: :government_overthrown, name: "Nova"},
        %{type: :seat_incapacitated, seat: :leader, name: "Nova", player_id: 1, reason: :afk}
      ]

      for event <- events do
        case GovRelay.render(:cardan, event) do
          nil -> :ok
          line -> refute line =~ "—", "em-dash in copy for #{inspect(event.type)}: #{line}"
        end
      end
    end

    test "post_async is a silent no-op when the relay is not running" do
      refute Process.whereis(GovRelay)

      assert GovRelay.post_async(1, :ark, %{type: :seat_changed, seat: :leader, player_id: 1, name: "N"}) ==
               :ok
    end
  end
end
