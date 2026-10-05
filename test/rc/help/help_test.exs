defmodule RC.HelpTest do
  use ExUnit.Case, async: true

  alias RC.Help.{Catalog, Charts, Compiler, Page, Source, Tables}

  setup_all do
    %{
      ctx:
        Compiler.context(
          "en",
          Compiler.base(%{slugs: %{"taxes" => "Taxes"}, aliases: %{"tax" => "taxes"}, categories: %{}})
        )
    }
  end

  describe "the compiled manual" do
    test "has no lint errors" do
      assert RC.Help.errors() == [], inspect(RC.Help.errors(), pretty: true)
    end

    test "compiles every page for every language and speed" do
      for lang <- RC.Help.languages(), {_slug, page} <- RC.Help.pages(lang), speed <- RC.Help.speeds() do
        assert is_binary(Map.fetch!(page.html, speed))
        assert page.lang == lang
      end
    end

    test "mobility page resolves constants, icons, links and tables" do
      page = RC.Help.page("mobility", "en")
      html = page.html[:slow]

      assert html =~ "0.1 credits"
      # [[taxes]] is an alias of the credit guide: the label stays, the link resolves.
      assert html =~ ~s(<a href="/help/credit" class="help-ref" data-help="credit">taxes</a>)
      assert html =~ ~s(<i class="help-icon" data-icon="resource/mobility" title="Mobility"></i>)
      # Orbital Link (lift_open) produces mobility; Reflect District (finance_open) scales with it.
      assert html =~ "Orbital Link"
      assert html =~ "Reflect District"
      # Singularity Ring has biome :gate and is never listed.
      refute html =~ "Singularity Ring"
      assert page.text =~ "Mobility"
    end

    test "localized names come from the language's data.json" do
      en = RC.Help.page("mobility", "en").html[:slow]
      fr = RC.Help.page("mobility", "fr").html[:slow]
      assert en =~ "Habitable Planets"
      refute fr =~ "Habitable Planets"
    end

    test "bundle is JSON-ready" do
      bundle = RC.Help.bundle("en", :slow)
      assert %{pages: [_ | _], categories: [_ | _], glossary: [_ | _]} = bundle
      assert Enum.any?(bundle.glossary, &(&1.term == "mobility" and &1.slug == "mobility"))
      assert {:ok, _} = Jason.encode(bundle)
    end

    test "the Basics of Play pages are featured, in reading order, with a one-line summary" do
      featured = RC.Help.featured("en")
      assert Enum.map(featured, & &1.slug) == ~w(strategy-basics early-game resource-focus late-game)

      for %{slug: slug, title: title, summary: summary} <- featured do
        assert RC.Help.page(slug).kind == :primer
        assert title != ""
        # the card's sentence: the page's first, whole (never cut at 160 characters)
        assert summary =~ ~r/^Learn .+\.$/, slug
        assert String.length(summary) <= 160, slug
      end

      assert %{featured: %{title: "Basics of Play", pages: [_, _, _, _]}} = RC.Help.bundle("en", :slow)
    end

    test "each Basics of Play page links to its example system in the planner" do
      for {slug, preset} <- [
            {"early-game", "basics-early"},
            {"resource-focus", "basics-mid"},
            {"late-game", "basics-late"}
          ] do
        html = RC.Help.page(slug).html[:slow]
        assert html =~ ~s(href="/portal/system-planner?preset=#{preset}"), slug
        assert html =~ ~s(data-shot="planner-#{preset}"), slug
      end
    end
  end

  describe "tokens" do
    test "constants follow the speed", %{ctx: ctx} do
      {slow, _, []} = Compiler.expand("{const:character_movement_factor}", %{ctx | speed: :slow}, "t")
      {fast, _, []} = Compiler.expand("{const:character_movement_factor}", %{ctx | speed: :fast}, "t")
      assert slow == "7.2"
      assert fast == "6"
    end

    test "unknown constant, name, ui string, icon and link are errors", %{ctx: ctx} do
      body = "{const:nope} {name:building.nope} {ui:no.such.key} {icon:resource/nope} [[nowhere]]"
      {_, _, issues} = Compiler.expand(body, ctx, "t")
      msgs = Enum.map(issues, & &1.msg)
      assert Enum.all?(issues, &(&1.level == :error))
      assert Enum.any?(msgs, &(&1 =~ "unknown constant `nope`"))
      assert Enum.any?(msgs, &(&1 =~ "unknown name `building.nope`"))
      assert Enum.any?(msgs, &(&1 =~ "unknown UI string"))
      assert Enum.any?(msgs, &(&1 =~ "unknown icon `resource/nope`"))
      assert Enum.any?(msgs, &(&1 =~ "unknown link target `nowhere`"))
    end

    test "a section alias links to the heading, and headings get anchor ids" do
      ctx =
        Compiler.context(
          "en",
          Compiler.base(%{
            slugs: %{"g" => "Guide"},
            aliases: %{"stacking" => "g"},
            alias_anchors: %{"stacking" => %{anchor: "how-bonuses-add-up", heading: "How bonuses add up"}},
            categories: %{}
          })
        )

      {md, placeholders, []} = Compiler.expand("See [[stacking]].", ctx, "t")

      assert Compiler.render(md, placeholders) =~
               ~s(<a href="/help/g#how-bonuses-add-up" class="help-ref" data-help="g" data-anchor="how-bonuses-add-up">How bonuses add up</a>)

      {page, _issues} = Compiler.compile_page(%Page{slug: "g", title: "Guide", body: "## How bonuses add up\n\nText."}, ctx)
      assert page.html[:slow] =~ ~s(<h2 id="how-bonuses-add-up">How bonuses add up</h2>)
      assert Compiler.anchor_id("What {icon:resource/credit} it gives") == "what-it-gives"
    end

    test "links resolve aliases and keep labels", %{ctx: ctx} do
      {md, placeholders, []} = Compiler.expand("see [[tax|the tax page]]", ctx, "t")
      html = Compiler.render(md, placeholders)
      assert html =~ ~s(<a href="/help/taxes" class="help-ref" data-help="taxes">the tax page</a>)
    end

    test "names and character names are singular", %{ctx: ctx} do
      {md, _, []} = Compiler.expand("{name:building.lift_open} / {name:character.admiral}", ctx, "t")
      assert md == "Orbital Link / Navarch"
    end

    test "ui strings translate their inline html to markdown", %{ctx: ctx} do
      {md, _, []} = Compiler.expand("{ui:character_reaction.flee}", ctx, "t")
      assert md =~ "**Deserter**"
      refute md =~ "<strong>"
      assert Compiler.ui_text("a <strong>b</strong> <em>c</em><br/>d <span>e</span>") == "a **b** *c* d e"
    end

    test "ported drawer pages compile with the same strings the panels use" do
      for slug <- ~w(hotkeys map-legend stances) do
        assert %{} = RC.Help.page(slug, "en"), "missing page #{slug}"
      end

      stances = RC.Help.page("stances", "en").html[:slow]
      assert stances =~ "Deserter"
      assert stances =~ ~s(data-icon="reaction/attack_everyone")
      refute stances =~ "dominion takeover"
      assert RC.Help.page("hotkeys", "en").html[:slow] =~ ~r/<code[^>]*>Ctrl<\/code>/
    end

    test "unknown table generator is an error and leaves a marker", %{ctx: ctx} do
      {md, _, [issue]} = Compiler.expand("{table:nope x}", ctx, "t")
      assert issue.level == :error
      assert md =~ "missing table: nope"
    end
  end

  describe "planner links" do
    test "{planner:} opens the system planner on a preset, in a new tab", %{ctx: ctx} do
      {md, placeholders, issues} = Compiler.expand("{planner:basics-early|Open Lyceum}", ctx, "p")
      assert issues == []
      html = Compiler.render(md, placeholders)

      assert html =~
               ~s(<a href="/portal/system-planner?preset=basics-early" class="help-planner-link" target="_blank" rel="noopener">Open Lyceum</a>)
    end

    test "a label is optional", %{ctx: ctx} do
      {md, placeholders, []} = Compiler.expand("{planner:basics-late}", ctx, "p")
      assert Compiler.render(md, placeholders) =~ ">Open it in the system planner</a>"
    end

    test "an unknown preset is a lint error and leaves no link", %{ctx: ctx} do
      {md, placeholders, issues} = Compiler.expand("{planner:nope|Open it}", ctx, "p")
      assert [%{level: :error, msg: msg}] = issues
      assert msg =~ "unknown planner preset `nope`"
      refute Compiler.render(md, placeholders) =~ "<a "
    end
  end

  describe "tables" do
    test "buildings_by_output lists producers with level ranges", %{ctx: ctx} do
      {:ok, md} = Tables.render(ctx, "buildings_by_output", ["sys_mobility"])
      assert md =~ "{icon:building/lift_open} Orbital Link"
      assert md =~ "{icon:building/spatioport_orbital} Orbital Terminus"
      assert md =~ "+1.5 → +7.5 Mobility"
      refute md =~ "hypergate"
    end

    test "bonus_sources lists lexes, traditions and skills but not buildings", %{ctx: ctx} do
      {:ok, md} = Tables.render(ctx, "bonus_sources", ["sys_mobility"])
      assert md =~ "Freedom of Movement"
      assert md =~ "Aeronautical Tycoon (A.R.K.)"
      refute md =~ "Orbital Link"
    end

    test "constants filters by prefix per speed", %{ctx: ctx} do
      {:ok, slow} = Tables.render(%{ctx | speed: :slow}, "constants", ["system_base_"])
      {:ok, fast} = Tables.render(%{ctx | speed: :fast}, "constants", ["system_base_"])
      assert slow =~ "| `system_base_defense` | 0.15 |"
      assert fast =~ "| `system_base_defense` | 0 |"
      assert {:error, _} = Tables.render(ctx, "constants", ["zzz_"])
    end

    test "population_classes lists classes from smallest, with victory points", %{ctx: ctx} do
      {:ok, md} = Tables.render(ctx, "population_classes", [])
      assert md =~ "| Outpost | 0 | 1 |"
      assert md =~ "| Nerve Center | 160 | 75 |"
      assert :binary.match(md, "Outpost") < :binary.match(md, "Nerve Center")
    end

    test "population_statuses shows stability ranges and hides the sentinel threshold", %{ctx: ctx} do
      {:ok, md} = Tables.render(ctx, "population_statuses", [])
      assert md =~ "| Normal | > 0 | — |"
      assert md =~ "| Discontentment | -10 < … ≤ 0 | -10 % |"
      assert md =~ "| Widespread rebellion | ≤ -30 | -80 % |"
      refute md =~ "10000"
    end

    test "stellar_bodies lists every body type with generation ranges", %{ctx: ctx} do
      {:ok, md} = Tables.render(ctx, "stellar_bodies", [])
      [_header, _sep | rows] = String.split(md, "\n")
      assert length(rows) == 6
      # Habitable planets: 6-8 tiles, up to one moon, potentials 1-5.
      assert Enum.any?(rows, &(&1 =~ "| 6–8 | 0–1 " and &1 =~ "| 1–5 | 1–5 | 1–5 |"))
      # Gas giants and asteroid belts have no tiles and no potentials.
      assert Enum.any?(rows, &(&1 =~ "| 0 | 1–3 " and &1 =~ "| — | — | — |"))
    end

    test "star_types lists body counts per star type", %{ctx: ctx} do
      {:ok, md} = Tables.render(ctx, "star_types", [])
      [_header, _sep | rows] = String.split(md, "\n")
      assert length(rows) == 6
      assert md =~ "| 6–8 |"
    end

    test "unknown keys are errors", %{ctx: ctx} do
      assert {:error, _} = Tables.render(ctx, "buildings_by_output", ["sys_nope"])
      assert {:error, _} = Tables.render(ctx, "building_levels", ["nope"])
      assert {:error, _} = Tables.render(ctx, "buildings_by_output", [])
      assert {:error, _} = Tables.render(ctx, "population_classes", ["x"])
    end

    test "table cells keep the pipes of links and tokens" do
      assert RC.Help.Format.cell("[[patent/a|A]] {icon:x|Y} 1|2") == "[[patent/a|A]] {icon:x|Y} 1\\|2"
    end

    test "whole amounts group their thousands per language", %{ctx: ctx} do
      assert RC.Help.Format.grouped(ctx, 462_000) == "462,000"
      assert RC.Help.Format.grouped(ctx, 1_500.0) == "1,500"
      assert RC.Help.Format.grouped(ctx, 950) == "950"
      assert RC.Help.Format.grouped(ctx, -12_345) == "-12,345"
      assert RC.Help.Format.grouped(%{ctx | lang: "fr"}, 462_000) == "462 000"
      assert RC.Help.Format.grouped(ctx, 2.8) == "2.8"
    end
  end

  describe "building catalog pages" do
    test "every building on a real body type has a catalog page named after it" do
      keys =
        for speed <- RC.Help.speeds(),
            b <- RC.Help.Data.buildings(speed),
            b.biome in [:open, :dome, :orbital],
            uniq: true,
            do: to_string(b.key)

      for key <- keys do
        page = RC.Help.page("building/#{key}")
        assert page, "no catalog page for building #{key}"
        assert page.kind == :catalog
        assert page.icon == "building/#{key}"
      end

      assert RC.Help.page("building/hab_open").title == "Residential District"
      refute RC.Help.page("building/hypergate")
    end

    test "the shell wraps the prose slot in facts, card, levels and unlocking", %{ctx: ctx} do
      page = %Page{slug: "building/factory_open", kind: :catalog, body: "Prose slot."}
      md = Catalog.body(ctx, page)
      assert md =~ ~r/\A\{facts:building factory_open\}\n\nProse slot\.\n\n\{card:building factory_open\}/
      assert md =~ "{table:building_levels factory_open}"
      assert md =~ "{table:building_unlock factory_open}"
      refute md =~ "shipyard_ships"
      assert Catalog.body(ctx, %{page | slug: "building/shipyard_1_orbital"}) =~ "{table:shipyard_ships shipyard_1_orbital}"
    end

    test "the card has a radio pip, a panel and a cost row per level", %{ctx: ctx} do
      b = Enum.find(RC.Help.Data.buildings(:slow), &(&1.key == :ideo_open))
      {:ok, html} = Catalog.block(ctx, "card", "building", "ideo_open")
      assert length(Regex.scan(~r/<input type="radio" name="help-bcard-ideo_open"/, html)) == length(b.levels)
      assert length(Regex.scan(~r/ checked>/, html)) == 1
      assert length(Regex.scan(~r/class="help-bcard-panel" data-level="\d+"/, html)) == length(b.levels)
      assert length(Regex.scan(~r/class="help-bcard-cost" data-level="\d+"/, html)) == length(b.levels)
      assert html =~ ~s(src="/img/help/buildings/#{b.illustration}")
      assert html =~ ~s(>Limited</span>)
    end

    test "facts show the limit badge and link the Buildings guide section once it exists", %{ctx: ctx} do
      {:ok, html} = Catalog.block(ctx, "facts", "building", "monument_dome")
      assert html =~ ~s(<span class="help-limit-badge" title="Can only build one per star system.">Unique</span>)
      refute html =~ "/help/buildings#"

      index =
        Map.merge(ctx.index, %{
          slugs: Map.put(ctx.index.slugs, "buildings", "Buildings"),
          aliases: Map.put(ctx.index.aliases, "unique-buildings", "buildings"),
          alias_anchors: %{"unique-buildings" => %{anchor: "unique-and-limited-buildings", heading: "Unique and Limited"}}
        })

      {:ok, linked} = Catalog.block(%{ctx | index: index}, "facts", "building", "monument_dome")
      assert linked =~ ~s(href="/help/buildings#unique-and-limited-buildings")

      {:ok, unlimited} = Catalog.block(ctx, "facts", "building", "hab_open")
      refute unlimited =~ "help-limit"
    end

    test "levels list what each level requires", %{ctx: ctx} do
      name = fn path -> get_in(ctx.en.data, path) end
      megapolis = name.(["building", "infra_open", "name"])

      {:ok, hab} = Catalog.table(ctx, "building_levels", "hab_open")
      assert hab =~ "#{megapolis} level 1"
      assert hab =~ "#{megapolis} level 5"

      {:ok, orbital} = Catalog.table(ctx, "building_levels", "mine_orbital")
      assert orbital =~ name.(["patent", "infra_orbital_2", "name"])
      refute orbital =~ "#{megapolis} level"

      {:ok, infra} = Catalog.table(ctx, "building_levels", "infra_open")
      assert infra =~ name.(["patent", "infra_open_2", "name"])
      refute infra =~ "#{megapolis} level"
    end

    test "unlocking walks the patent tree from its root", %{ctx: ctx} do
      name = fn key -> get_in(ctx.en.data, ["patent", key, "name"]) end
      {:ok, md} = Catalog.table(ctx, "building_unlock", "factory_open")
      assert md =~ "**#{name.("open_industries")}**"
      assert [first] = Regex.run(~r/^1\. .*$/m, md)
      assert first =~ name.("citadel")
      assert md =~ ~r/^3\. .*#{Regex.escape(name.("open_industries"))}$/m
      assert {:ok, "No patent is needed to build it."} = Catalog.table(ctx, "building_unlock", "hab_open")
    end

    test "shipyards name the ship classes they build", %{ctx: ctx} do
      assert {:ok, fighters} = Catalog.table(ctx, "shipyard_ships", "shipyard_1_orbital")
      assert fighters =~ "- Fighters"
      assert {:ok, capitals} = Catalog.table(ctx, "shipyard_ships", "shipyard_4_orbital")
      assert capitals =~ "- Capital ships"
    end

    test "a building missing from a speed says so instead of a shell", %{ctx: ctx} do
      fast = RC.Help.Data.buildings(:fast) |> Enum.map(& &1.key)

      case Enum.find(RC.Help.Data.buildings(:slow), &(&1.key not in fast and &1.biome in [:open, :dome, :orbital])) do
        nil ->
          :ok

        b ->
          md = Catalog.body(%{ctx | speed: :fast}, %Page{slug: "building/#{b.key}", kind: :catalog, body: "x"})
          assert md == "{absent:building #{b.key}}"
          refute md =~ "{card:"

          assert {:ok, html} = Catalog.block(%{ctx | speed: :fast}, "absent", "building", to_string(b.key))
          assert html =~ "The game mode you&#39;re viewing, <strong>Flash</strong>, doesn&#39;t have this building."
          assert html =~ ~s(class="help-speed-switch" data-speed="slow">Legacy</a>)
      end
    end

    test "catalog prose slots warn above three sentences" do
      page = %Page{slug: "building/hab_open", kind: :catalog, body: "One. Two. Three. Four."}
      assert Enum.any?(Compiler.lint_prose(page), &(&1.msg =~ "at most 3"))
      refute Enum.any?(Compiler.lint_prose(%{page | body: "One. Two. Three."}), &(&1.msg =~ "at most 3"))
    end

    test "compiled building pages carry the card and the generated sections" do
      page = RC.Help.page("building/factory_open")
      html = page.html[:slow]
      assert html =~ ~s(<figure class="help-bcard" data-building="factory_open">)
      assert html =~ ~s(<h2 id="levels">)
      # Block HTML is never left inside a paragraph, even with Earmark's newline after <p>.
      refute html =~ ~r/<p>\s*<(figure|div)/
      refute page.text =~ "help-bcard"
    end

    test "buildings_list has one row per building of the speed", %{ctx: ctx} do
      listed = fn speed -> Enum.filter(RC.Help.Data.buildings(speed), &(&1.biome in [:open, :dome, :orbital])) end
      rows = fn md -> md |> String.split("\n") |> Enum.drop(2) |> length() end

      {:ok, slow} = Tables.render(ctx, "buildings_list", [])
      {:ok, fast} = Tables.render(%{ctx | speed: :fast}, "buildings_list", [])
      assert rows.(slow) == length(listed.(:slow))
      assert rows.(fast) == length(listed.(:fast))
      assert slow =~ "| {icon:building/monument_dome} Monolith | Barren Planets | Unique | 3 | 5 |"
      refute slow =~ "hypergate"
    end

    test "upgrade_patents gives each level's infrastructure and orbital patents", %{ctx: ctx} do
      name = fn key -> get_in(ctx.en.data, ["patent", key, "name"]) end
      {:ok, md} = Tables.render(ctx, "upgrade_patents", [])
      assert md =~ "| 2 | #{name.("infra_open_2")} | #{name.("infra_dome_2")} | #{name.("infra_orbital_2")} |"
      assert md =~ "| 5 | #{name.("infra_open_5")} |"
      assert {:ok, ""} = Tables.render(%{ctx | speed: :fast}, "upgrade_patents", [])
    end

    test "buildings_by_tag lists buildings by content tag", %{ctx: ctx} do
      tagged = RC.Help.Data.buildings(:slow) |> Enum.count(&(&1.biome in [:open, :dome, :orbital] and :defense in &1.outputs))
      {:ok, md} = Tables.render(ctx, "buildings_by_tag", ["defense"])
      assert md |> String.split("\n") |> Enum.drop(2) |> length() == tagged
      assert md =~ "{icon:building/radar_orbital}"
      assert {:error, _} = Tables.render(ctx, "buildings_by_tag", ["nope"])
    end

    test "facts carry the siege line only for siege-weighted buildings", %{ctx: ctx} do
      {:ok, radar} = Catalog.block(ctx, "facts", "building", "radar_orbital")
      assert radar =~ "Twice as likely to be damaged"
      {:ok, hab} = Catalog.block(ctx, "facts", "building", "hab_open")
      refute hab =~ "Twice as likely"
    end

    test "per-tick amounts in tables and cards follow the reader's unit", %{ctx: ctx} do
      {:ok, credit} = Tables.render(ctx, "buildings_by_output", ["sys_credit"])
      assert credit =~ ~r/\{amount:[+-][\d.]+\}/
      assert credit =~ "{units:"

      {:ok, mobility} = Tables.render(ctx, "buildings_by_output", ["sys_mobility"])
      refute mobility =~ "{amount:"
      refute mobility =~ "{units:"

      {:ok, levels} = Catalog.table(ctx, "building_levels", "market_dome")
      assert levels =~ "{amount:"
      assert levels =~ "{units:"

      {:ok, card} = Catalog.block(ctx, "card", "building", "market_dome")
      assert card =~ ~s(<span class="help-amount"><span class="help-unit-tick">)
      assert card =~ ~r/<span class="help-unit-hour">\+[\d.,k]+\/h<\/span>/

      page = %Page{slug: "amounts", body: "Gain {amount:+2.8}, {amount:-0.05} and {amount:+6000}. {units:Per tick.|Per hour.}"}
      {compiled, issues} = Compiler.compile_page(page, ctx)
      html = compiled.html[:slow]
      assert html =~ ~s(<span class="help-unit-tick">+2.8</span><span class="help-unit-hour">+56/h</span>)
      assert html =~ ~s(<span class="help-unit-hour">-1/h</span>)
      assert html =~ ~s(<span class="help-unit-hour">+120k/h</span>)
      assert html =~ ~s(<span class="help-unit-tick">Per tick.</span><span class="help-unit-hour">Per hour.</span>)
      refute Enum.any?(issues, &(&1.level == :error))
    end

    test "building pages lead back to the Buildings guide and to upgrades once those pages exist", %{ctx: ctx} do
      page = %Page{slug: "building/hab_open", kind: :catalog, body: ""}
      refute Catalog.body(ctx, page) =~ "[[upgrades]]"
      {:ok, bare} = Catalog.block(ctx, "facts", "building", "hab_open")
      refute bare =~ "help-partof"

      index = Map.merge(ctx.index, %{slugs: Map.merge(ctx.index.slugs, %{"buildings" => "Buildings", "upgrades" => "Upgrades"})})
      linked = %{ctx | index: index}
      assert Catalog.body(linked, page) =~ ~r/## Levels\n\nEvery level above 1 is an upgrade\. See \[\[upgrades\]\]/
      # A one-level building (every building at Flash) has no upgrades to point to.
      refute Catalog.body(%{linked | speed: :fast}, %{page | slug: "building/mine_dome"}) =~ "Every level above 1"
      {:ok, facts} = Catalog.block(linked, "facts", "building", "hab_open")
      assert facts =~ ~s(<p class="help-partof">Part of the <a href="/help/buildings" class="help-ref" data-help="buildings">Buildings</a> guide</p>)
    end

    test "the manual recompiles when the set of page files changes" do
      refute RC.Help.__mix_recompile__?()
    end

    test "every compiled page with a per-tick amount carries both units" do
      for {slug, page} <- RC.Help.pages("en"), html = page.html[:slow], html =~ "help-amount" do
        amounts = Regex.scan(~r/<span class="help-amount">(.*?)<\/span><\/span>/, html)

        assert Enum.all?(amounts, fn [_, inner] -> inner =~ "help-unit-tick" and inner =~ "help-unit-hour" end),
               "#{slug}: an amount lacks a unit variant"
      end
    end
  end

  describe "patent and lex catalog pages" do
    alias RC.Help.ResearchCatalog

    test "every patent and lex of any speed has a catalog page" do
      for {kind, keys} <- [
            patent: Enum.flat_map([:slow, :medium, :fast], &RC.Help.Data.patents/1),
            lex: Enum.flat_map([:slow, :medium, :fast], &RC.Help.Data.doctrines/1)
          ],
          key <- keys |> Enum.map(& &1.key) |> Enum.uniq() do
        assert RC.Help.page("#{kind}/#{key}"), "no page for #{kind}/#{key}"
      end
    end

    test "a patent page wraps the prose in facts, card, unlocks and the path from the root", %{ctx: ctx} do
      md = Catalog.body(ctx, %Page{slug: "patent/open_industries", kind: :catalog, body: "PROSE"})
      assert md =~ ~r/\{facts:patent open_industries\}\s+PROSE\s+\{card:patent open_industries\}/
      assert md =~ "## Unlocks"
      assert md =~ "- {icon:building/factory_open} Industrial Hub"
      assert md =~ "## Unlocking"
      assert md =~ "1. {icon:patent/citadel}"
    end

    test "the levels of one technology share a page, and each level's slug opens it on that level" do
      for stem <- ~w(infra_open infra_dome infra_orbital merge_fighter merge_corvette merge_frigate),
          {level, key} <- ResearchCatalog.family_levels(stem) do
        assert RC.Help.resolve("patent/#{key}") == "patent/#{stem}"
        assert RC.Help.alias_anchor("patent/#{key}") == "level-#{level}"
        refute "patent/#{key}" in RC.Help.slugs()
      end

      page = RC.Help.page("patent/infra_open_3")
      assert page.slug == "patent/infra_open"
      assert page.title == "Urbanization"
      assert page.icon == "patent/infra_open_1"
      assert RC.Help.page("patent/infra_orbital").title == "Pressurized Environment"
      assert RC.Help.page("patent/merge_fighter").title == "Fighter Formation"
      assert RC.Help.page("patent/infra_open", "fr").title == "Urbanisation"

      # Numbered patents with names of their own are not levels: a page each.
      assert ResearchCatalog.family_level(:infra_open_3) == {"infra_open", 3}
      assert ResearchCatalog.family_level(:shipyard_2) == nil
      assert ResearchCatalog.family_level(:merge_fighter_corvette) == nil
      assert RC.Help.page("patent/shipyard_2").slug == "patent/shipyard_2"

      # The SPA opens an alias at its anchor.
      bundled = Enum.find(RC.Help.bundle("en", :slow).pages, &(&1.slug == "patent/infra_open"))
      assert bundled.alias_anchors["patent/infra_open_3"] == "level-3"
      assert "patent/infra_open_3" in bundled.aliases
    end

    test "a page of levels lists each level's price, requirement and unlocks", %{ctx: ctx} do
      md = Catalog.body(ctx, %Page{slug: "patent/infra_open", kind: :catalog, body: "PROSE"})
      assert md =~ ~r/\A\{facts:patent infra_open\}\s+PROSE\s+\{card:patent infra_open\}\s+## Levels/
      assert md =~ "| {icon:patent/infra_open_2} II | 400 | Urbanization | Megapolis level 2; Convention Center; Allows for buildings"
      assert md |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "| {icon:patent/infra_open_")) == 5
      # The top level's path runs through the lower levels, in bold, and the patents between them.
      assert md =~ ~r/## Unlocking.*1\. \{icon:patent\/citadel\}.*\*\*Urbanization II\*\*\n4\. \{icon:patent\/open_ideo\}.*\*\*Urbanization V\*\*\z/s
      refute md =~ "## Unlocks"

      {:ok, facts} = Catalog.block(ctx, "facts", "patent", "infra_open")
      assert facts =~ "<dt>Levels</dt><dd>I, II, III, IV, V</dd>"
      assert facts =~ "50 – 20,000"
      assert facts =~ "+5 % of it for each patent you own"

      # Moons and asteroids need no patent for level 1: the page starts at II.
      {:ok, orbital} = Catalog.block(ctx, "facts", "patent", "infra_orbital")
      assert orbital =~ "<dd>II, III, IV, V</dd>"
    end

    test "the card of a page of levels flips between them like a building card", %{ctx: ctx} do
      {:ok, html} = Catalog.block(ctx, "card", "patent", "infra_orbital")
      assert html =~ ~s(<figure class="help-bcard help-rcard" data-patent="infra_orbital">)
      # Pips count positions, so the first level this speed has shows by default; ids are the level anchors.
      assert html =~ ~s(<input type="radio" name="help-bcard-patent-infra_orbital" value="1" id="level-2" checked><span>II</span>)
      assert html =~ ~s(<input type="radio" name="help-bcard-patent-infra_orbital" value="4" id="level-5"><span>V</span>)
      assert length(Regex.scan(~r/ checked>/, html)) == 1
      assert length(Regex.scan(~r/class="help-bcard-panel" data-level="\d"/, html)) == 4
      assert length(Regex.scan(~r/class="help-bcard-cost" data-level="\d"/, html)) == 4
      assert html =~ ~s(<div class="help-bcard-swap" data-level="2">Pressurized Environment III</div>)
      assert html =~ "Allows for orbital buildings to be upgraded to level 4"

      # Every level uses one picture here; Fighter Formation has one per level.
      assert length(Regex.scan(~r/<img /, html)) == 1
      {:ok, fighters} = Catalog.block(ctx, "card", "patent", "merge_fighter")
      assert length(Regex.scan(~r/<img /, fighters)) == 3

      # One level at a speed: no selector.
      {:ok, frigates} = Catalog.block(ctx, "card", "patent", "merge_frigate")
      refute frigates =~ "help-bcard-pips"
    end

    test "a page of levels follows the speed's own levels", %{ctx: ctx} do
      fast = %{ctx | speed: :fast}
      {:ok, facts} = Catalog.block(fast, "facts", "patent", "merge_fighter")
      assert facts =~ "<dd>I, III</dd>"
      assert Catalog.body(fast, %Page{slug: "patent/infra_orbital", kind: :catalog, body: "x"}) == "{absent:patent infra_orbital}"
      {:ok, absent} = Catalog.block(fast, "absent", "patent", "infra_orbital")
      assert absent =~ ~s(<a href="/help/patent/infra_orbital" class="help-speed-switch" data-speed="slow">Legacy</a>)

      # At every speed the top level's path runs through every lower level.
      for speed <- [:slow, :medium, :fast],
          stem <- ~w(infra_open infra_dome infra_orbital merge_fighter merge_corvette merge_frigate),
          levels = ResearchCatalog.family(speed, stem),
          levels != [] do
        {_n, top} = List.last(levels)
        path = speed |> ResearchCatalog.chain(:patent, top.key) |> Enum.map(& &1.key)
        assert Enum.all?(levels, fn {_n, p} -> p.key in path end), "#{stem} at #{speed}"
      end
    end

    test "links to one level land on the shared page at that level" do
      html = RC.Help.page("building/infra_open").html[:slow]

      assert html =~
               ~s(<a href="/help/patent/infra_open#level-2" class="help-ref" data-help="patent/infra_open" data-anchor="level-2">Urbanization II</a>)

      page = RC.Help.page("patent/infra_open")
      assert page.html[:slow] =~ ~s(<h2 id="levels">)
      refute page.text =~ "help-bcard"
      # The page never links to itself.
      refute page.html[:slow] =~ ~s(href="/help/patent/infra_open#)
    end

    test "a lex page lists benefits, then drawbacks", %{ctx: ctx} do
      md = Catalog.body(ctx, %Page{slug: "lex/credit_pop", kind: :catalog, body: ""})
      assert md =~ ~r/\*\*Benefits\*\*.*\*\*Drawbacks\*\*\s+- -25 % Defense/s
      # Lower upkeep is a benefit, higher upkeep a drawback.
      assert ResearchCatalog.drawback?(%Core.Bonus{from: :army_maintenance, to: :army_maintenance, type: :mul, value: 0.05})
      refute ResearchCatalog.drawback?(%Core.Bonus{from: :army_maintenance, to: :army_maintenance, type: :mul, value: -0.1})
    end

    test "facts give the base price and how it grows", %{ctx: ctx} do
      assert {:ok, html} = Catalog.block(ctx, "facts", "patent", "shipyard_2")
      assert html =~ "3,000"
      assert html =~ "+5 % of it for each patent you own"
      assert {:ok, html} = Catalog.block(%{ctx | speed: :fast}, "facts", "lex", "agent")
      assert html =~ "+20 % of it for each lex you own"
    end

    test "a key missing at the viewed speed links the speeds that have it", %{ctx: ctx} do
      md = Catalog.body(%{ctx | speed: :fast}, %Page{slug: "patent/open_intel", kind: :catalog, body: "x"})
      assert md == "{absent:patent open_intel}"
      {:ok, html} = Catalog.block(%{ctx | speed: :fast}, "absent", "patent", "open_intel")
      assert html =~ ~s(data-speed="slow">Legacy</a> or <a href="/help/patent/open_intel" class="help-speed-switch" data-speed="medium">Tactic</a>)
      {:ok, html} = Catalog.block(ctx, "absent", "patent", "merge_fighter_corvette")
      assert html =~ ~s(data-speed="fast">Flash</a>.)
      refute html =~ "Tactic"
    end

    test "price_scaling shows the same patent and lex as later purchases", %{ctx: ctx} do
      assert {:ok, md} = Tables.render(ctx, "price_scaling", [])
      assert md =~ "| 10th | ×1.45 | 4,350 | 4,350 |"
      assert {:ok, fast} = Tables.render(%{ctx | speed: :fast}, "price_scaling", [])
      refute fast =~ "| 40th"
    end

    test "lex_slot_costs doubles until the cap", %{ctx: ctx} do
      assert {:ok, md} = Tables.render(ctx, "lex_slot_costs", [])
      assert md =~ "| 2nd | 200 |"
      assert md =~ "| 10th | 51,200 |"
      assert md =~ "| 11th and every slot after it | 100,000 |"
    end

    test "lex_change_waits and its chart follow the game's rule", %{ctx: ctx} do
      assert {:ok, md} = Tables.render(ctx, "lex_change_waits", [])
      assert md =~ "| 1st | {duration:6} |"
      assert md =~ "| 3rd | {duration:14} |"
      assert ResearchCatalog.lex_wait(:fast, 1) == 26
      assert {:ok, chart} = Charts.render(ctx, "lex_change_waits", [])
      assert chart.tick =~ "Wait (ticks)"
      assert chart.hour =~ "Wait (hours)"
      assert {:ok, fast} = Charts.render(%{ctx | speed: :fast}, "lex_change_waits", [])
      assert fast.hour =~ "Wait (minutes)"
    end

    test "traditions lists four per playable faction", %{ctx: ctx} do
      assert {:ok, md} = Tables.render(ctx, "traditions", [])
      assert md =~ "| Tetrarchy | Aphera Research Centers |"
      assert md |> String.split("
") |> Enum.count(&String.starts_with?(&1, "| Cardan |")) == 4
      # The Rebel Defense bot faction has traditions, but no player can join it.
      refute md =~ "The Rebellion"
    end

    test "patents_list and lexes_list have one row per node of the speed", %{ctx: ctx} do
      for {gen, fun} <- [{"patents_list", &RC.Help.Data.patents/1}, {"lexes_list", &RC.Help.Data.doctrines/1}],
          speed <- [:slow, :fast] do
        assert {:ok, md} = Tables.render(%{ctx | speed: speed}, gen, [])
        rows = md |> String.split("
") |> Enum.count(&String.starts_with?(&1, "| {icon:"))
        assert rows == length(fun.(speed)), "#{gen} at #{speed}"
      end
    end

    test "daily challenge races are listed last, as a side use", %{ctx: ctx} do
      md = Catalog.body(ctx, %Page{slug: "patent/capital_1", kind: :catalog, body: ""})
      assert md =~ ~r/## Unlocking.*## Also used in\n\n- Daily challenge race The Destroyer's Blueprint: buying this patent completes it\.\z/s
      md = Catalog.body(ctx, %Page{slug: "building/monument_open", kind: :catalog, body: ""})
      assert md =~ "- Daily challenge race Monumental: finishing this building completes it."
      refute Catalog.body(ctx, %Page{slug: "patent/citadel", kind: :catalog, body: ""}) =~ "Also used in"
    end

    test "short durations read in minutes or seconds for the per-hour reader", %{ctx: ctx} do
      {md, ph, []} = Compiler.expand("{duration:6}", ctx, "t")
      assert Compiler.render(md, ph) =~ ~s(<span class="help-unit-hour">18 min</span>)
      {md, ph, []} = Compiler.expand("{duration:26}", %{ctx | speed: :fast}, "t")
      assert Compiler.render(md, ph) =~ ~s(<span class="help-unit-hour">39 s</span>)
    end
  end

  describe "lint" do
    test "flags internal names and adjectives of quality" do
      issues = Compiler.lint_prose(%Page{slug: "x", body: "The admiral has a powerful sys_defense bonus."})
      msgs = Enum.map(issues, & &1.msg)
      assert Enum.any?(msgs, &(&1 =~ "internal names in prose"))
      assert Enum.any?(msgs, &(&1 =~ "adjectives of quality: powerful"))
    end

    test "ignores tokens and code blocks" do
      body = "{name:character.admiral} is fine.\n\n    admiral in code\n\n```\nspy\n```\n"
      assert Compiler.lint_prose(%Page{slug: "x", body: body}) == []
    end

    test "a primer has no word cap" do
      body = String.duplicate("Word word word word word. ", 200)
      assert Compiler.lint_prose(%Page{slug: "x", kind: :primer, body: body}) == []
    end

    test "warns on long prose" do
      body = String.duplicate("Word word word word word. ", 52)
      assert [%{level: :warning, msg: msg}] = Compiler.lint_prose(%Page{slug: "x", body: body})
      assert msg =~ "260 words"
    end

    test "flags semicolons, dashes, long sentences and typed time" do
      body =
        "Growth slows; it stops. It adds — more. It pays 2 credits per tick. " <>
          String.duplicate("word ", 30) <> "end."

      msgs = %Page{slug: "x", body: body} |> Compiler.lint_prose() |> Enum.map(& &1.msg)
      assert Enum.any?(msgs, &(&1 =~ "semicolon"))
      assert Enum.any?(msgs, &(&1 =~ "dash"))
      assert Enum.any?(msgs, &(&1 =~ "over 25 words"))
      assert Enum.any?(msgs, &(&1 =~ "time typed in prose"))
    end

    test "an advanced block renders folded and does not count toward the length cap", %{ctx: ctx} do
      body = "Main text.\n\n{advanced}\n\n## How it rolls\n\nDeep detail.\n\n{/advanced}\n\nAfter.\n"
      {page, _issues} = Compiler.compile_page(%Page{slug: "a", title: "A", body: body}, ctx)
      html = page.html[:slow]

      assert html =~ ~s(<details class="help-advanced"><summary>Advanced mechanics</summary><div class="help-advanced-body">)
      assert html =~ ~s(<h2 id="how-it-rolls">How it rolls</h2>)
      refute html =~ "{advanced}"
      assert page.text =~ "Deep detail."

      long = String.duplicate("Word word word word word. ", 40)
      assert [] = Compiler.lint_prose(%Page{slug: "x", body: "Short.\n\n{advanced}\n\n" <> long <> "\n{/advanced}\n"})

      twice = "A.\n\n{advanced}\n\nB.\n\n{/advanced}\n\n{advanced}\n\nC.\n"
      assert [%{msg: msg}] = Compiler.lint_prose(%Page{slug: "x", body: twice})
      assert msg =~ "at most one"
    end

    test "a page can record that it is long on purpose, with a reason" do
      body = String.duplicate("Word word word word word. ", 40)
      assert [] = Compiler.lint_prose(%Page{slug: "x", body: body, length: "long", length_reason: "Many separate rules."})

      assert [%{msg: msg}] = Compiler.lint_prose(%Page{slug: "x", body: body, length: "long"})
      assert msg =~ "needs a `length_reason:`"

      assert {:ok, meta, _, []} =
               Source.parse_frontmatter("---\ntitle: T\nlength: long\nlength_reason: Many rules.\n---\nbody\n")

      assert meta["length"] == "long"
    end

    test "guide pages have a larger length cap than leaves" do
      body = String.duplicate("Word word word word word. ", 40)
      assert [%{msg: msg}] = Compiler.lint_prose(%Page{slug: "x", body: body})
      assert msg =~ "cap for a mechanic page is 180"
      assert [] = Compiler.lint_prose(%Page{slug: "x", kind: :guide, body: body})
    end
  end

  describe "time units, charts, screenshots and guides" do
    test "rates and durations carry a per-tick and a per-hour variant", %{ctx: ctx} do
      {md, ph, []} = Compiler.expand("{rate:0.002|population} and {duration:150}", %{ctx | speed: :slow}, "t")
      html = Compiler.render(md, ph)

      assert html =~
               ~s(<span class="help-unit-tick">0.002 population per tick</span><span class="help-unit-hour">0.04 population per hour</span>)

      assert html =~ ~s(<span class="help-unit-tick">150 ticks</span><span class="help-unit-hour">7.5 hours</span>)

      {md, ph, []} = Compiler.expand("{rate:system_population_taxes_factor|credits}", %{ctx | speed: :slow}, "t")
      assert Compiler.render(md, ph) =~ "2 credits per tick"
    end

    test "unknown rate constant and unknown screenshot are errors", %{ctx: ctx} do
      {_, _, issues} = Compiler.expand("{rate:nope} {shot:nope#x}", ctx, "t")
      msgs = Enum.map(issues, & &1.msg)
      assert Enum.any?(msgs, &(&1 =~ "unknown constant `nope`"))
      assert Enum.any?(msgs, &(&1 =~ "unknown screenshot `nope`"))
    end

    test "screenshots render numbered highlight marks from the manifest", %{ctx: ctx} do
      shot = %{
        "file" => "box.png",
        "width" => 400,
        "height" => 200,
        "alt" => "Box",
        "marks" => %{"a" => %{"x" => 0.1, "y" => 0.2, "w" => 0.3, "h" => 0.4}, "b" => %{"x" => 0, "y" => 0, "w" => 1, "h" => 1}}
      }

      ctx = %{ctx | shots: %{"box" => shot}}
      {md, ph, []} = Compiler.expand("{shot:box#a,b|The box}", ctx, "t")
      html = Compiler.render(md, ph)

      assert html =~ ~s(<img src="/img/help/shots/box.png" alt="Box" width="400" height="200" loading="lazy">)

      assert html =~
               ~s(<span class="help-shot-mark" data-n="1" style="left:10.00%;top:20.00%;width:30.00%;height:40.00%"></span>)

      assert html =~ "<figcaption>The box</figcaption>"
      refute html =~ "<p><figure"

      {_, _, [issue]} = Compiler.expand("{shot:box#c}", ctx, "t")
      assert issue.msg =~ "no mark `c`"
    end

    test "population_growth chart draws one line per stability bonus, in ticks and in hours", %{ctx: ctx} do
      {:ok, chart} = Charts.render(ctx, "population_growth", ["housing=40", "bonus=0,20"])
      assert chart.tick =~ ~s(class="help-chart-line s1")
      refute chart.tick =~ "help-chart-line s2"
      assert chart.tick =~ ">ticks</text>"
      assert chart.hour =~ ">hours</text>"
      assert chart.caption =~ "40 housing"
      assert {:error, _} = Charts.render(ctx, "population_growth", ["nope=1"])
      assert {:error, _} = Charts.render(ctx, "population_growth", ["housing=1,2"])
      assert {:error, _} = Charts.render(ctx, "nope", [])
    end

    test "population_growth follows the game's growth rule" do
      alias Instance.StellarSystem.StellarSystem
      assert StellarSystem.population_growth(40, 20, -11, 0.02) == -0.002
      assert StellarSystem.population_growth(40, 20, -5, 0.02) == -0.001
      assert StellarSystem.population_growth(40, 45, 10, 0.02) < 0
      assert StellarSystem.population_growth(40, 20, 30, 0.02) > StellarSystem.population_growth(40, 20, 10, 0.02)
    end

    test "speeds table gives the real length of a tick and ticks per hour", %{ctx: ctx} do
      {:ok, md} = Tables.render(ctx, "speeds", [])
      assert md =~ "| Legacy | 3 min | 20 |"
      assert md =~ "| Flash | 1.5 s | 2400 |"
      refute md =~ "daily"
    end

    test "guides list their pages and pages point back to their guide", %{ctx: ctx} do
      guide = %Page{slug: "g", title: "Guide", kind: :guide, html: %{slow: "<p>G</p>"}, text: "G."}
      leaf = %Page{slug: "l", title: "Leaf", guide: "g", html: %{slow: "<p>L</p>"}, text: "Leaf is short. More."}
      pages = Compiler.decorate_guides(%{"g" => guide, "l" => leaf}, ctx)

      assert pages["l"].html.slow =~
               ~s(<p class="help-partof">Part of the <a href="/help/g" class="help-ref" data-help="g">Guide</a> guide</p><p>L</p>)

      assert pages["g"].html.slow =~ ~s(<span class="help-guide-blurb">Leaf is short.</span>)
      assert pages["l"].text == "Leaf is short. More."
    end
  end

  describe "frontmatter" do
    test "parses scalars, inline lists and block lists" do
      src = "---\ntitle: T\nterms: [a, b]\nsources:\n  - lib/x.ex:1-2\n  - lib/y.ex\nstatus: draft\n---\nbody\n"
      assert {:ok, meta, "body\n", []} = Source.parse_frontmatter(src)

      assert meta == %{
               "title" => "T",
               "terms" => ["a", "b"],
               "sources" => ["lib/x.ex:1-2", "lib/y.ex"],
               "status" => "draft"
             }
    end

    test "warns on unknown keys and rejects missing block" do
      assert {:ok, _, _, ["unknown frontmatter key `foo`"]} = Source.parse_frontmatter("---\ntitle: T\nfoo: 1\n---\n")
      assert {:error, {:frontmatter, _}} = Source.parse_frontmatter("no frontmatter")
      assert {:error, {:frontmatter, _}} = Source.parse_frontmatter("---\ntitle: T\n")
    end
  end
end
