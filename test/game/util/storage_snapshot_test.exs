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
        }
      ]
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
    # dependency-closure atom universe and then decodes fine.
    assert {:ok, decoded} = :peer.call(peer, Util.Storage, :decode_binary, [binary], 30_000)
    assert %{agents_data: [_, _]} = decoded

    :peer.stop(peer)
  end
end
