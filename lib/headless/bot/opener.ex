defmodule Headless.Bot.Opener do
  @moduledoc """
  Scripted opening books (game-ai-v2.md §V2.1).

  The first ~200 UT of every faction's game are rote and near-forced:
  build the starter tech building, housing, unlock citadel, build the
  Citadel, buy + activate the first lex, buy Urbanization. Refusing any
  of these makes a real game unwinnable — so the opening is CODE (the V2
  "legality is code" principle), and the genome only picks WHICH viable
  variant to run (`opener_variant` gene).

  A book is a list of variants; a variant is a list of steps. Steps are
  declarative: `done?/2` is re-derived from observable view state every
  decision (policies never see execution results), `attempt/2` emits at
  most one action, and blocked steps simply wait — the engine validates,
  refusals are normal. While a purchase step saves income, the book
  allows a bounded FILLER house ("another house could be built while
  waiting" — user rule). A stuck opener (pathological map, no eligible
  tile) hands over after `@timeout_ut` rather than freezing the bot in
  book mode; the timeout is recorded and counts against the champion's
  `opener_rate` deployment gate.

  The genome's `credit_floor` is deliberately ignored here: a
  pathological evolved floor must not be able to starve the forced
  opening (the shipped Generalist's 14.8k floor did exactly that).
  """

  alias Headless.Policies.HomeDev

  @timeout_ut 600
  @floor 500
  @max_fillers 2

  # {key, biome, uniqueness, tile_kind, credit_cost} for opener builds —
  # Fast-mode data, same source as Tunable's catalog.
  @builds %{
    university_open: {:open, :unique_body, :normal, 3_360},
    hab_open_poor: {:open, :none, :normal, 2_900},
    ideo_open: {:open, :unique_body, :normal, 3_360},
    infra_open: {:open, :unique_body, :infrastructure, 12_000}
  }

  # The forced core, in the user's canonical order (2026-07-05):
  # tech building → housing → citadel patent (50 tech) → Citadel →
  # Age of Exploration lex, activated → Urbanization patent. Factions
  # with starting tech/ideo income simply clear the waits faster.
  #
  # DT-3b (2026-07-17): the core ends by ORDERING the first infra (+12
  # stability, +8 housing). Overnight proof: cp25 stability sat at 7 for
  # 12.8h with the growth-kit floors available — the first quarter is
  # opener-bound (the kit can't fire before handover, and the first infra
  # then lands ~cp25-30). ASYNC step: the order is placed and the book
  # moves on — a blocking wait for the ~150-UT build would delay every
  # variant's tail (notably colonial's transport patent) by that much.
  @core [
    {:build, :university_open},
    {:build, :hab_open_poor},
    {:patent, :citadel, 50},
    {:build, :ideo_open},
    {:doctrine, :agent, 50},
    {:policies, [:agent]},
    {:patent, :infra_open_1, 400},
    {:build_async, :infra_open}
  ]

  @doc """
  The opening book for a faction. All five share the same forced core
  today; variants differ in what the STARTING deck agent does. Books are
  per-faction so future variants can diverge (lex-save targets, sterile
  beeline vs. second habitable) without touching the policy.
  """
  def book(_faction) do
    [
      %{key: :governor_open, steps: @core ++ [{:starting_agent, :governor}]},
      %{key: :scout_open, steps: @core ++ [{:starting_agent, :deploy}]},
      # Colonization-primed: after the forced core, save straight into the
      # transport patent before handing over — added 2026-07-05 when the
      # book's tempo shock left 85%+ of the population zero-colony for 5+
      # hours with no self-recovery. Evolution chooses whether the earlier
      # colonization chain beats the earlier free economy.
      %{key: :colonial_open, steps: @core ++ [{:patent, :transport_1, 600}, {:starting_agent, :governor}]},
      # Exobiology rush (user 2026-07-09): beeline the research patent —
      # infra_open_1 (in core) -> infra_dome_1 -> open_research — because
      # research_open is the only big tech-income building besides the base
      # university, and tech income is what funds every patent/lex. The
      # trade against the colonial variant is early tech economy vs. early
      # expansion; the genome's opener_variant gene picks. If a slow-tech
      # genome can't afford the beeline it times out and hands over, which
      # (rightly) counts against its deployment gate.
      %{key: :exobiology_open, steps: @core ++ [{:patent, :infra_dome_1, 2000}, {:patent, :open_research, 4500}, {:starting_agent, :governor}]}
    ]
  end

  @doc "Initial opener state for a genome, at the bot's first decision."
  def new(genome, view) do
    book = book(view.player.faction)
    idx = genome |> Map.get("opener_variant", 0.0) |> trunc() |> abs() |> rem(length(book))
    variant = Enum.at(book, idx)

    %{
      variant: variant.key,
      steps: variant.steps,
      fillers: 0,
      started_ut: view.now_ut,
      done: false,
      timed_out: false,
      # Keys of {:build_async, _} steps whose order has been PLACED — the
      # authoritative done-marker (inferring from queue-busy misfired:
      # filler builds satisfied it and infra was silently skipped).
      async_done: MapSet.new()
    }
  end

  @doc """
  One opener decision: `{actions, state}`. `state.done` flips when every
  step's predicate holds (or the timeout valve fires); after that the
  evolved policy owns every decision.
  """
  def step(%{done: true} = state, _view), do: {[], state}

  def step(state, view) do
    cond do
      Enum.all?(state.steps, &step_done?(&1, view, state)) ->
        {[], %{state | done: true}}

      timed_out?(state, view) ->
        {[], %{state | done: true, timed_out: true}}

      true ->
        pending = Enum.filter(state.steps, &(not step_done?(&1, view, state)))

        case attempt_pending(pending, view) do
          :wait -> filler(state, view)
          {actions, {:build_async, key}} -> {actions, %{state | async_done: MapSet.put(state.async_done, key)}}
          {actions, _step} -> {actions, state}
        end
    end
  end

  # Attempt the first pending step; an async build that can't order yet
  # (saving toward its cost) YIELDS to the next step instead of blocking
  # the book — variant tails (e.g. colonial's transport patent) proceed
  # while the infra fund accumulates.
  defp attempt_pending([], _view), do: :wait

  defp attempt_pending([step | rest], view) do
    case attempt(step, view) do
      :wait ->
        case step do
          {:build_async, _} -> attempt_pending(rest, view)
          _ -> :wait
        end

      actions ->
        {actions, step}
    end
  end

  defp step_done?({:build_async, key} = step, view, state),
    do: MapSet.member?(state.async_done, key) or done?(step, view)

  defp step_done?(step, view, _state), do: done?(step, view)

  defp timed_out?(state, view) do
    is_number(view.now_ut) and is_number(state.started_ut) and
      view.now_ut - state.started_ut > @timeout_ut
  end

  # --- step predicates (observable state only) -------------------------------

  defp done?({:build, key}, view) do
    Enum.any?(view.systems, fn {_id, system} ->
      system.bodies |> HomeDev.flatten_bodies() |> Enum.any?(&HomeDev.has_building?(&1, key))
    end)
  end

  # Async build: the placed-order marker lives in opener state (see
  # step_done?/3); this clause only recognizes the completed building.
  defp done?({:build_async, key}, view), do: done?({:build, key}, view)

  defp done?({:patent, key, _cost}, view), do: key in view.player.patents
  defp done?({:doctrine, key, _cost}, view), do: key in view.player.doctrines
  defp done?({:policies, keys}, view), do: Enum.all?(keys, &(&1 in view.player.policies))

  # Agent steps are done when the deck has been spent (or was empty to
  # begin with) — whichever seat the variant chose.
  defp done?({:starting_agent, :governor}, view) do
    ready_deck(view) == [] or Enum.any?(view.systems, fn {_id, s} -> s.governor != nil end) or
      map_size(view.characters) > 0
  end

  defp done?({:starting_agent, :deploy}, view) do
    ready_deck(view) == [] or map_size(view.characters) > 0
  end

  # --- step attempts -----------------------------------------------------------

  defp attempt({:build, key}, view), do: order_build(view, key) || :wait
  defp attempt({:build_async, key}, view), do: order_build(view, key) || :wait

  defp attempt({:patent, key, cost}, view) do
    if view.player.technology.value >= cost, do: [{:purchase_patent, key}], else: :wait
  end

  defp attempt({:doctrine, key, cost}, view) do
    if view.player.ideology.value >= cost, do: [{:purchase_doctrine, key}], else: :wait
  end

  defp attempt({:policies, keys}, _view), do: [{:update_policies, keys}]

  defp attempt({:starting_agent, mode}, view) do
    case ready_deck(view) do
      [%{character: %{id: id, type: type}} | _] ->
        [%{id: home_id} | _] = view.player.stellar_systems
        # A starting ADMIRAL is the faction's colonizer — it goes ON BOARD
        # regardless of variant. Benching it as a governor left tetrarchy
        # (whose deck starts with an admiral) structurally unable to build
        # a single transport (2026-07-06 colonization RCA:
        # blocks=%{colonize_no_ready_transport: 116}, transports_built=0).
        seat = if mode == :governor and type != :admiral, do: :governor, else: :on_board
        [{:activate_character, id, seat, home_id}]

      _ ->
        :wait
    end
  end

  defp ready_deck(view) do
    Enum.filter(view.player.character_deck, &match?(%{cooldown: nil}, &1))
  end

  # The whole wait-filler rule: at most @max_fillers extra builds, only
  # while some purchase step is accumulating income. UNIVERSITIES, not
  # poor habs (2026-07-12): hab_open_poor costs -5 happiness against a
  # Fast-mode base of 12, and the opener's core already spends one — two
  # more put happiness at -3 and POPULATION SHRINKS before the genome ever
  # takes over (pop growth flips negative below 0 happiness). A second/
  # third university on other bodies is pure upside: tech income directly
  # accelerates the very patent steps the opener is waiting on.
  defp filler(%{fillers: n} = state, view) when n < @max_fillers do
    case order_build(view, :university_open) do
      nil -> {[], state}
      actions -> {actions, %{state | fillers: n + 1}}
    end
  end

  defp filler(state, _view), do: {[], state}

  defp order_build(view, key) do
    {biome, limit, tile_kind, cost} = Map.fetch!(@builds, key)

    if view.player.credit.value >= cost + @floor do
      Enum.find_value(view.systems, fn {system_id, system} ->
        with true <- HomeDev.queue_idle?(system),
             bodies = HomeDev.flatten_bodies(system.bodies),
             {body, tile} when body != nil <- HomeDev.find_slot(bodies, biome, key, limit, tile_kind) do
          [{:order_building, system_id, body.uid, tile.id, key}]
        else
          _ -> nil
        end
      end)
    end
  end
end
