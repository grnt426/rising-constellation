defmodule Instance.Contracts.IntegrationTest do
  @moduledoc """
  Boots the REAL `Instance.Contracts.Agent` and `Instance.Player.Agent`s (plus a tiny
  fake `:time` agent) and drives the full lifecycle through `Game.call`/`Game.cast`,
  asserting the things the pure unit tests cannot: that the bounty is actually escrowed
  off the payer, that payout/refund actually move credits across agents, and that a
  dispute applies strikes. This is the proof that the runtime wiring (Player.Agent
  create handler ↔ Contracts.Agent ↔ Time ↔ credit casts) holds together.
  """
  use ExUnit.Case, async: false

  alias Instance.Contracts.Contracts
  alias Instance.Player.Player

  # Minimal stand-in for the `:time` agent. The contracts agent only reads
  # `time.now.value`, so a nested map is enough.
  defmodule FakeTime do
    use GenServer

    def start(iid, now), do: GenServer.start_link(__MODULE__, now, name: Game.via_tuple({iid, :time, :master}))

    @impl true
    def init(now), do: {:ok, now}

    @impl true
    def handle_call(:get_state, _from, now), do: {:reply, {:ok, %{now: %{value: now}}}, now}
  end

  setup do
    iid = System.unique_integer([:positive])
    # Instance metadata must exist before any Core.GenState.new/5 — it reads the
    # speed/constants for that instance. Mirrors Test.FleetScenario.load_game_data/2.
    Data.Data.insert(iid, speed: :fast, mode: :dev)

    {:ok, time} = FakeTime.start(iid, 0.0)
    contracts = start_contracts(iid)

    on_exit(fn ->
      Process.exit(time, :kill)
      Process.exit(contracts, :kill)
      Data.Data.clear(iid)
    end)

    %{iid: iid}
  end

  describe "create" do
    test "escrows the bounty off the payer and lists the contract", %{iid: iid} do
      start_player(iid, 1, 10_000, with_admiral_in: 100)

      assert {:ok, contract} = Game.call(iid, :player, 1, {:create_contract, contract_params()})
      assert contract.status == :listed
      assert contract.payer_id == 1
      assert contract.bounty == 1000
      # bounty escrowed immediately
      assert credit(iid, 1) == 9000
    end

    test "is rejected (no debit) without a deployed agent of the category", %{iid: iid} do
      start_player(iid, 1, 10_000, systems: [%{id: 100}])

      assert {:error, :missing_agent_for_category} =
               Game.call(iid, :player, 1, {:create_contract, contract_params()})

      assert credit(iid, 1) == 10_000
    end

    test "is rejected (no debit) when the bounty exceeds the payer's credit", %{iid: iid} do
      start_player(iid, 1, 500, with_admiral_in: 100)

      assert {:error, :not_enough_credit} =
               Game.call(iid, :player, 1, {:create_contract, contract_params()})

      assert credit(iid, 1) == 500
    end
  end

  describe "claim" do
    test "activates the contract and locks the fees", %{iid: iid} do
      start_player(iid, 1, 10_000, with_admiral_in: 100)
      start_player(iid, 2, 0)
      {:ok, contract} = Game.call(iid, :player, 1, {:create_contract, contract_params()})

      assert {:ok, claimed} = Game.call(iid, :contracts, :master, {:claim, contract.id, 2})
      assert claimed.status == :active
      assert claimed.performer_id == 2
      # no strikes yet -> base 5% each on a 1000 bounty
      assert claimed.listing_fee == 50
      assert claimed.closing_fee == 50
    end

    test "cannot claim your own contract", %{iid: iid} do
      start_player(iid, 1, 10_000, with_admiral_in: 100)
      {:ok, contract} = Game.call(iid, :player, 1, {:create_contract, contract_params()})

      assert {:error, :cannot_claim_own_contract} =
               Game.call(iid, :contracts, :master, {:claim, contract.id, 1})
    end
  end

  describe "resolution" do
    test "pay + claim pays the performer the bounty minus fees", %{iid: iid} do
      start_player(iid, 1, 10_000, with_admiral_in: 100)
      start_player(iid, 2, 0)
      {:ok, contract} = Game.call(iid, :player, 1, {:create_contract, contract_params()})
      {:ok, _} = Game.call(iid, :contracts, :master, {:claim, contract.id, 2})

      {:ok, _} = Game.call(iid, :contracts, :master, {:submit_closure, contract.id, 1, "pay"})
      {:ok, resolved} = Game.call(iid, :contracts, :master, {:submit_closure, contract.id, 2, "claim"})

      assert resolved.status == :paid
      # 1000 - 50 listing - 50 closing = 900 to the performer (async cast)
      eventually(fn -> assert credit(iid, 2) == 900 end)
      # payer is not refunded on a payout
      assert credit(iid, 1) == 9000

      # the performer gets a text notification about the payout (async cast; stored
      # because the test player is "offline" and the notif is keep?: true)
      eventually(fn ->
        {:ok, performer} = Game.call(iid, :player, 2, :get_state)
        assert Enum.any?(performer.pending_notifications, &(&1.key == :contract_paid))
      end)
    end

    test "a dispute refunds the payer and strikes both parties", %{iid: iid} do
      start_player(iid, 1, 10_000, with_admiral_in: 100)
      start_player(iid, 2, 0)
      {:ok, contract} = Game.call(iid, :player, 1, {:create_contract, contract_params()})
      {:ok, _} = Game.call(iid, :contracts, :master, {:claim, contract.id, 2})

      {:ok, _} = Game.call(iid, :contracts, :master, {:submit_closure, contract.id, 2, "claim"})
      {:ok, resolved} = Game.call(iid, :contracts, :master, {:submit_closure, contract.id, 1, "dispute"})

      assert resolved.status == :disputed
      # full bounty back to the payer (async cast): 9000 + 1000 = 10000
      eventually(fn -> assert credit(iid, 1) == 10_000 end)
      # performer gets nothing
      assert credit(iid, 2) == 0
      # both parties carry a permanent strike (applied synchronously in the registry)
      {:ok, data} = Game.call(iid, :contracts, :master, :get_state)
      assert Contracts.strikes(data, 1) == 1
      assert Contracts.strikes(data, 2) == 1
    end

    test "the disputed contract's higher fees show up on the next deal", %{iid: iid} do
      start_player(iid, 1, 10_000, with_admiral_in: 100)
      start_player(iid, 2, 0)

      # First deal -> dispute -> both at 1 strike.
      {:ok, c1} = Game.call(iid, :player, 1, {:create_contract, contract_params()})
      {:ok, _} = Game.call(iid, :contracts, :master, {:claim, c1.id, 2})
      {:ok, _} = Game.call(iid, :contracts, :master, {:submit_closure, c1.id, 2, "claim"})
      {:ok, _} = Game.call(iid, :contracts, :master, {:submit_closure, c1.id, 1, "dispute"})

      # Second deal between the same two: combined 2 strikes -> 0.05 + 2*0.03 = 0.11.
      {:ok, c2} = Game.call(iid, :player, 1, {:create_contract, contract_params()})
      {:ok, claimed} = Game.call(iid, :contracts, :master, {:claim, c2.id, 2})
      assert claimed.listing_fee == 110
      assert claimed.closing_fee == 110
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp start_contracts(iid) do
    channel = "instance:global:#{iid}"
    gen_state = Core.GenState.new(:contracts, iid, :master, Contracts.new(iid), channel)
    {:ok, pid} = Instance.Contracts.Agent.start_link(state: gen_state)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp start_player(iid, id, credit, opts \\ []) do
    {systems, characters} =
      case Keyword.get(opts, :with_admiral_in) do
        nil -> {Keyword.get(opts, :systems, []), []}
        sys -> {[%{id: sys}], [%{type: :admiral, status: :on_board, system: sys}]}
      end

    player =
      struct(Player, %{
        id: id,
        account_id: id + 10_000,
        faction_id: 1,
        faction: :tetrarchy,
        name: "p#{id}",
        is_dead: false,
        is_active: true,
        credit: Core.DynamicValue.new(credit),
        technology: Core.DynamicValue.new(0),
        ideology: Core.DynamicValue.new(0),
        stellar_systems: systems,
        dominions: [],
        characters: characters,
        connected_clients: 0,
        pending_notifications: []
      })

    channel = "instance:player:#{iid}:#{id}"
    gen_state = Core.GenState.new(:player, iid, id, player, channel)
    {:ok, pid} = Instance.Player.Agent.start_link(state: gen_state)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp credit(iid, id) do
    {:ok, player} = Game.call(iid, :player, id, :get_state)
    player.credit.value
  end

  defp contract_params(overrides \\ %{}) do
    Map.merge(
      %{
        "action_category" => "admiral",
        "action_type" => "guard_fleet",
        "bounty" => 1000,
        "duration" => 30,
        "max_claimant_strikes" => 5,
        "note" => "escort my envoy"
      },
      overrides
    )
  end

  # Poll an assertion until it passes or the budget runs out — payout/refund are async
  # casts, so the credit may land a beat after the resolving call returns.
  defp eventually(fun, retries \\ 50) do
    try do
      fun.()
    rescue
      e in ExUnit.AssertionError ->
        if retries > 0 do
          Process.sleep(10)
          eventually(fun, retries - 1)
        else
          reraise e, __STACKTRACE__
        end
    end
  end
end
