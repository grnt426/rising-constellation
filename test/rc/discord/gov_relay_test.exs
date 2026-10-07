defmodule RC.Discord.GovRelayTest do
  @moduledoc """
  Pure-renderer tests for the faction-government Discord relay. The
  GenServer itself never runs here — `render/2` is a pure function of
  (faction_key, event), and the forwarding whitelist is data.
  """

  use ExUnit.Case, async: true

  alias RC.Discord.GovRelay

  describe "render_votes/3 — the faction's own channel" do
    test "one election opening names the seat in the faction's words, who is on the ballot and when it closes" do
      message =
        GovRelay.render_votes(:tetrarchy, :opened, [
          %{
            ballot_id: 1,
            seat: :leader,
            question: :elect,
            kind: :plurality,
            candidates: ["Nova", "Vex"],
            target: nil,
            closes_at: 1_800_000_000
          }
        ])

      assert message ==
               "🗳️ A vote has opened. **Tetrarch**: election. On the ballot: Nova, Vex. " <>
                 "Voting closes <t:1800000000:R>. Vote or abstain in game."
    end

    test "several seats opening together share one message, closing at the earliest deadline" do
      ballot = fn seat, closes_at ->
        %{seat: seat, question: :elect, kind: :stake_pledge, candidates: [], closes_at: closes_at}
      end

      message =
        GovRelay.render_votes(:cardan, :opened, [ballot.(:leader, 200), ballot.(:economy, 100)])

      assert message ==
               "🗳️ Votes have opened.\n" <>
                 "- **Eminence**: tithe offering.\n" <>
                 "- **Circle of the Golden Palm**: tithe offering.\n" <>
                 "Voting closes <t:100:R>. Vote or abstain in game."
    end

    test "confirmations, depositions, crisis votes and referendums say who or what is at stake" do
      opened = fn key, ballot -> GovRelay.render_votes(key, :opened, [ballot]) end

      assert opened.(:synelle, %{seat: :economy, question: :approve, kind: :approval, candidates: ["Nova"]}) =~
               "**Interior Ministry**: confirmation of Nova."

      assert opened.(:myrmezir, %{seat: :military, question: :depose, kind: :approval, target: "Vex"}) =~
               "**Department of Defense**: vote to depose Vex."

      assert opened.(:synelle, %{seat: :leader, question: :dissolve, kind: :approval, target: "Vex"}) =~
               "**President**: crisis vote to remove Vex."

      assert opened.(:myrmezir, %{seat: :laws, question: :laws, kind: :approval, candidates: []}) =~
               "**Law referendum**: The leadership proposes to change the laws."

      assert opened.(:ark, %{seat: :leader, question: :elect, kind: :stake_bid, candidates: []}) =~
               "**Executive**: auction."
    end

    test "a seat that just opened says how a member gets on its ballot" do
      opened = fn key, candidacy ->
        GovRelay.render_votes(key, :opened, [
          %{seat: :leader, question: :elect, kind: :plurality, candidates: [], open_candidacy: candidacy}
        ])
      end

      assert opened.(:myrmezir, :self_only) =~ "**President**: election. Any member can stand. Vote"
      assert opened.(:cardan, :others_only) =~ "election. Members nominate one another. Vote"
      assert opened.(:synelle, :anyone) =~ "election. Any member can stand or be nominated. Vote"
      assert opened.(:ark, :by_stake) =~ "election. Bid on any member to put them forward. Vote"
      refute opened.(:myrmezir, :self_only) =~ "On the ballot"
    end

    test "a referendum says who proposes it and what it would enact and repeal" do
      opened = fn laws ->
        GovRelay.render_votes(:myrmezir, :opened, [
          %{seat: :laws, question: :laws, kind: :approval, candidates: [], proposed_by: "Nova", laws: laws}
        ])
      end

      assert opened.(%{enact: [:war_footing], repeal: [:civic_pride, :assembly_charter]}) =~
               "**Law referendum**: Nova proposes to enact War Footing and repeal Civic Pride, Assembly Charter."

      assert opened.(%{enact: [:war_footing], repeal: []}) =~ "Nova proposes to enact War Footing."
      assert opened.(%{enact: [], repeal: [:civic_pride]}) =~ "Nova proposes to repeal Civic Pride."
      assert opened.(%{enact: [], repeal: []}) =~ "Nova proposes to change the laws."
    end

    test "a ballot the agent could not describe still gets a line, without a deadline" do
      message = GovRelay.render_votes(:tetrarchy, :opened, [%{ballot_id: 3, seat: :leader, question: :elect}])
      assert message == "🗳️ A vote has opened. **Tetrarch**: election. Vote or abstain in game."
    end

    test "results name the winner, or why nobody was seated" do
      closed = fn key, event -> GovRelay.render_votes(key, :closed, [event]) end

      assert closed.(:tetrarchy, %{
               type: :ballot_closed,
               seat: :leader,
               question: :elect,
               outcome: :seated,
               winner: %{player_id: 2, name: "Nova"}
             }) == "🗳️ A vote has closed. **Tetrarch**: Nova wins the seat."

      assert closed.(:tetrarchy, %{seat: :leader, question: :elect, outcome: :no_votes, winner: nil}) =~
               "**Tetrarch**: no vote was cast. No one is seated."

      assert closed.(:cardan, %{seat: :leader, question: :elect, outcome: :quorum_not_met, winner: nil}) =~
               "**Eminence**: the offering fell short. No one is seated."
    end

    test "results of the other questions read as their verdict" do
      closed = fn key, event -> GovRelay.render_votes(key, :closed, [event]) end

      assert closed.(:synelle, %{seat: :economy, question: :approve, outcome: :rejected, candidates: ["Nova"]}) =~
               "**Interior Ministry**: Nova is rejected."

      assert closed.(:tetrarchy, %{seat: :leader, question: :depose, outcome: :approved, target: "Vex"}) =~
               "**Tetrarch**: Vex is deposed."

      # Cardan's loss of faith passes as a pledge that reached its quorum
      assert closed.(:cardan, %{
               seat: :leader,
               question: :depose,
               outcome: :seated,
               target: "Vex",
               winner: %{player_id: 1, name: "Vex"}
             }) =~ "**Eminence**: Vex is deposed."

      assert closed.(:cardan, %{seat: :leader, question: :depose, outcome: :quorum_not_met, target: "Vex"}) =~
               "**Eminence**: Vex keeps the seat."

      assert closed.(:synelle, %{seat: :leader, question: :dissolve, outcome: :rejected, target: "Vex"}) =~
               "**President**: the crisis vote failed."

      assert closed.(:myrmezir, %{seat: :laws, question: :laws, outcome: :approved, candidates: []}) =~
               "**Law referendum**: the change of laws is adopted."
    end

    test "a failed round closes every seat in one message" do
      events =
        for seat <- [:leader, :economy] do
          %{type: :ballot_closed, seat: seat, question: :elect, outcome: :no_candidates, winner: nil}
        end

      assert GovRelay.render_votes(:myrmezir, :closed, events) ==
               "🗳️ Votes have closed.\n" <>
                 "- **President**: nobody stood. No one is seated.\n" <>
                 "- **Economic Advisor**: nobody stood. No one is seated."
    end

    test "nothing to say, nothing posted; and no em-dash in any of it" do
      assert GovRelay.render_votes(:ark, :opened, []) == nil
      assert GovRelay.render_votes(:ark, :closed, []) == nil

      message =
        GovRelay.render_votes(:ark, :closed, [
          %{seat: :leader, question: :elect, outcome: :quorum_rounds_exhausted, winner: nil},
          %{seat: :economy, question: :dissolve, outcome: :approved, target: "Vex"}
        ])

      refute message =~ "—"
    end

    test "the channel is the faction category's #general" do
      assert GovRelay.votes_channel?(%{id: 9, parent_id: 5, name: "general"}, 5)
      refute GovRelay.votes_channel?(%{id: 9, parent_id: 5, name: "strategy"}, 5)
      refute GovRelay.votes_channel?(%{id: 9, parent_id: 6, name: "general"}, 5)
    end
  end

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
               "Nova (Discord: kurtz) is now the Leader of A.R.K. <:ark:1528019447812456519>."
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

    test "votes_async is a silent no-op when the relay is not running" do
      refute Process.whereis(GovRelay)
      assert GovRelay.votes_async(1, :ark, :opened, [%{seat: :leader, question: :elect}]) == :ok
      assert GovRelay.votes_async(1, :ark, :closed, []) == :ok
    end

    test "post_async is a silent no-op when the relay is not running" do
      refute Process.whereis(GovRelay)

      assert GovRelay.post_async(1, :ark, %{type: :seat_changed, seat: :leader, player_id: 1, name: "N"}) ==
               :ok
    end
  end
end
