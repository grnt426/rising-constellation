defmodule RC.HelpTest do
  use ExUnit.Case, async: true

  alias RC.Help.{Charts, Compiler, Page, Source, Tables}

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
