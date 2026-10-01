defmodule Util.StorageSnapshotTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Snapshot decode must survive a FRESH BEAM — the deploy-boot situation
  where an instance snapshot is restored before anything has loaded the
  modules whose struct/field atoms it references. `binary_to_term(:safe)`
  rejects atoms that aren't interned yet, which twice broke restore in
  dev: once via Instance.Faction.Government (new :rc struct) and once via
  BehaviorTree.Node (a DEPENDENCY struct in system-AI state whose
  repeat_count/repeat_total atoms appear in no :rc module literal).

  The test boots a peer BEAM over stdio (no distribution required) with
  only the code PATH — no app modules loaded — and decodes there. A
  canary assertion first proves the peer genuinely lacks the atoms, so
  this test cannot rot into always-green if peers ever start inheriting
  more state.
  """

  # A snapshot-shaped term covering the two historical offenders plus the
  # usual Core value structs: a Government (with a live pledge ballot) and
  # a BehaviorTree.Node as system-AI state would embed it.
  defp snapshot_like_term do
    ballot =
      Instance.Faction.Government.Ballot.new(1, %{
        kind: :stake_pledge,
        seat: :leader,
        group: "round-1",
        candidates: [%{player_id: 2, name: "Pledgee"}],
        open_candidacy: :others_only,
        duration: 960,
        quorum: %{kind: :ideology_income_pct, pct: 5}
      })

    government = %{
      Instance.Faction.Government.new(%{constants: %{government_founding_duration: 1440}})
      | ballots: [ballot],
        phase: :running
    }

    %{
      instance_data: %{speed: :slow, mode: :prod},
      agents_data: [
        %{module: Instance.Faction.Agent, state: %{government: government}},
        %{
          module: Instance.StellarSystem.Agent,
          # NOTE: every atom in this term must come from a module literal
          # of :rc or its deps — that is the entire contract under test.
          # A field key minted with String.to_atom at runtime would break
          # real deploy-boot restore exactly like it breaks this test; if
          # you hit that here with a new state field, fix the field, not
          # the test.
          state: %{
            data: %BehaviorTree.Node{
              type: :repeat_n,
              children: [:noop],
              repeat_count: 2,
              repeat_total: 3
            },
            cooldown: Core.CooldownValue.new(40),
            value: Core.DynamicValue.new(10)
          }
        },
        # A Rebel Defense Warlord, with the gauge and refusal keys produced by
        # the REAL functions: runtime-built names (:"hostile_#{key}",
        # :"erased_#{action}") kept game 185 in maintenance after the
        # 2026-09-28 deploys, because a fresh VM has never created them.
        %{module: Wave.Warlord.Agent, state: %{data: warlord_state()}}
      ]
    }
  end

  defp warlord_state do
    hostiles = [
      %{type: :admiral, besieging_ours?: true, transient?: false},
      %{type: :spy, besieging_ours?: false, transient?: true}
    ]

    refused =
      Map.new(~w(assassination sabotage roam infiltrate), fn action ->
        {{Wave.Warlord.erased_refusal_key(action), :other}, 1}
      end)

    # Practice: learned Intelligence, the training Navarch and the practice
    # tallies, as a resolved practice strike leaves them.
    {practised, _payload} =
      Wave.Warlord.new(1, :rebellion)
      |> Wave.Warlord.track_erased(7, %{theatre: :field, duty: :removal})
      |> Wave.Warlord.erased_dispatched(7, 40, %{action: "infiltrate", training: true, cover: 90.0})
      |> Wave.Warlord.learn_intel(40, 3)
      |> Wave.Warlord.set_training_dummy(31)
      |> Wave.Warlord.count(:erased_practice)
      |> Wave.Warlord.resolve_erased(7, %{cover_after: 60.0, ci: 3.0})

    # Siderian trades: roles, a converted seducer, a resolved destabilization,
    # a stability reading, an evading agent and a reserve Navarch.
    {traded, _payload} =
      practised
      |> Wave.Warlord.track_siderian(20, :destab)
      |> Wave.Warlord.adopt_siderian(21, :seduce)
      |> Wave.Warlord.siderian_dispatched(20, 40, %{action: "encourage_hate", training: true, target_key: {:system, 40}})
      |> Wave.Warlord.resolve_siderian_action(20, %{penalty: 15, defence: 6.0})

    traded =
      traded
      |> Wave.Warlord.record_destab(40, 6.0, 15, 0.01, -30)
      |> Wave.Warlord.siderian_evading(21, 41, 40)
      |> Wave.Warlord.hold_convert_navarch(22)
      |> Wave.Warlord.gauge(:siderian_quotas, Wave.Siderian.quotas(9, %{capture: 40, destab: 30, seduce: 30}, 0))
      |> Wave.Warlord.refuse(:destab, :dropped_by_engine)
      |> Wave.Warlord.refuse(:evade, :no_route)

    %{
      gauges: Map.merge(Wave.Recon.gauges(hostiles, [1, 2]), traded.gauges),
      stats: Map.update!(traded.stats, :refused, &Map.merge(&1, refused)),
      erased: practised.erased,
      erased_intel: practised.erased_intel,
      training_dummy: practised.training_dummy,
      siderians: traded.siderians,
      siderian_intel: traded.siderian_intel,
      convert_navarchs: traded.convert_navarchs
    }
  end

  defp start_fresh_peer do
    args =
      :code.get_path()
      |> Enum.flat_map(fn path -> [~c"-pa", path] end)

    {:ok, pid, _node} = :peer.start_link(%{connection: :standard_io, args: args})
    pid
  end

  test "snapshot binaries safe-decode in a fresh BEAM (deploy-boot restore)" do
    binary = :erlang.term_to_binary(snapshot_like_term())
    peer = start_fresh_peer()

    # Canary: the raw :safe decode MUST fail in the peer — if it ever
    # passes, the peer inherited our atom table and this test proves
    # nothing anymore. (MFA only: anonymous funs can't cross into the
    # peer — the test module's beam exists only in this VM's memory.)
    canary =
      try do
        _ = :peer.call(peer, :erlang, :binary_to_term, [binary, [:safe]])
        :decoded
      rescue
        _ -> :rejected
      catch
        _, _ -> :rejected
      end

    assert canary == :rejected,
           "peer BEAM already had all snapshot atoms interned — fresh-BEAM regression coverage is void"

    # The real assertion: the production decode path interns the app's
    # dependency-closure atom universe and then decodes fine. Generous
    # timeout: the fresh peer walks and loads the whole dependency
    # closure from disk, which can crawl when the container is busy
    # (dev server + live instances) — this test is about correctness,
    # not speed.
    assert {:ok, decoded} = :peer.call(peer, Util.Storage, :decode_binary, [binary], 120_000)
    assert %{agents_data: [_, _, %{state: %{data: %{gauges: %{hostile_fleets: 1}}}}]} = decoded

    :peer.stop(peer)
  end
end
