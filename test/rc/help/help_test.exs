defmodule RC.HelpTest do
  use ExUnit.Case, async: true

  alias RC.Help.{Compiler, Page, Source, Tables}

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

      assert html =~ "0.1 credits per point of population"
      assert html =~ ~s(<a href="/help/taxes" class="help-ref" data-help="taxes">taxes</a>)
      assert html =~ ~s(<i class="help-icon" data-icon="resource/mobility" title="Mobility"></i>)
      # Orbital Link (lift_open) produces mobility; Reflect District (finance_open) scales with it.
      assert html =~ "Orbital Link"
      assert html =~ "Reflect District"
      # Singularity Ring has biome :gate and is never listed.
      refute html =~ "Singularity Ring"
      assert page.text =~ "Mobility raises that income"
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

    test "links resolve aliases and keep labels", %{ctx: ctx} do
      {md, placeholders, []} = Compiler.expand("see [[tax|the tax page]]", ctx, "t")
      html = Compiler.render(md, placeholders)
      assert html =~ ~s(<a href="/help/taxes" class="help-ref" data-help="taxes">the tax page</a>)
    end

    test "names and character names are singular", %{ctx: ctx} do
      {md, _, []} = Compiler.expand("{name:building.lift_open} / {name:character.admiral}", ctx, "t")
      assert md == "Orbital Link / Navarch"
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

    test "unknown keys are errors", %{ctx: ctx} do
      assert {:error, _} = Tables.render(ctx, "buildings_by_output", ["sys_nope"])
      assert {:error, _} = Tables.render(ctx, "building_levels", ["nope"])
      assert {:error, _} = Tables.render(ctx, "buildings_by_output", [])
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
      body = String.duplicate("word ", 260)
      assert [%{level: :warning, msg: msg}] = Compiler.lint_prose(%Page{slug: "x", body: body})
      assert msg =~ "260 words"
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
