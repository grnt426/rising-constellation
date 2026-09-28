defmodule Portal.HelpLiveTest do
  use Portal.HTMLConnCase

  describe "GET /help" do
    test "lists categories, pages and the glossary without JS", %{conn: conn} do
      html = conn |> get("/help") |> html_response(200)

      assert html =~ "<h1>Manual</h1>"
      assert html =~ ~s(href="/help/mobility")
      assert html =~ "Glossary"
      assert html =~ "Systems"
      assert html =~ "Numbers shown for <strong>Legacy</strong>"
    end

    test "?q= searches titles, terms and text", %{conn: conn} do
      html = conn |> get("/help", q: "mobility bonus") |> html_response(200)
      assert html =~ "Results for"
      assert html =~ ~s(href="/help/mobility")

      html = conn |> get("/help", q: "zzzzqqq") |> html_response(200)
      assert html =~ "No page matches."
    end

    test "?unit=hour is kept in page links and the search form", %{conn: conn} do
      html = conn |> get("/help", unit: "hour") |> html_response(200)
      assert html =~ ~s(href="/help/mobility?unit=hour")
      assert html =~ ~s(<input type="hidden" name="unit" value="hour")

      html = conn |> get("/help") |> html_response(200)
      refute html =~ ~s(name="unit")
      assert html =~ ~s(href="/help?unit=hour")
    end

    test "search works live", %{conn: conn} do
      {:ok, view, _} = live(conn, "/help")
      html = render_change(view, "search", %{"q" => "taxes"})
      assert html =~ "Results for"
      assert html =~ ~s(href="/help/credit")
    end
  end

  describe "GET /help/:slug" do
    test "renders the compiled page with sprite icons and links", %{conn: conn} do
      html = conn |> get("/help/mobility") |> html_response(200)

      assert html =~ "Mobility"
      assert html =~ "Mobility — Manual"
      # Compiled icon markers became sprite references…
      assert html =~ ~s(<use href="/img/help-icons.svg#resource--mobility"/>)
      refute html =~ ~s(<i class="help-icon")
      # …tables and links came through the sanitizer.
      assert html =~ "Orbital Link"
      assert html =~ ~s(<a href="/help/credit" class="help-ref" data-help="credit">taxes</a>)
      assert html =~ "Related"
    end

    test "?speed= switches the variant and is kept in links", %{conn: conn} do
      html = conn |> get("/help/population", speed: "fast") |> html_response(200)
      assert html =~ "Numbers shown for <strong>Flash</strong>"
      assert html =~ ~s(href="/help/credit?speed=fast")
      # A new colony starts with 5 population on Flash and 15.8 on Legacy.
      assert html =~ "starts with 5 population"
      refute html =~ "15.8"
    end

    test "?unit=hour switches the rate variant and is kept in links", %{conn: conn} do
      html = conn |> get("/help/population", unit: "hour") |> html_response(200)
      assert html =~ ~s(class="help-body help-units-hour")
      assert html =~ ~s(href="/help/credit?unit=hour")
      assert html =~ ~s(href="/help?unit=hour")

      # Combined with a speed, both survive link clicks. Body links are
      # rewritten inside the raw compiled HTML, so the & is not escaped.
      html = conn |> get("/help/population", speed: "fast", unit: "hour") |> html_response(200)
      assert html =~ ~s(href="/help/credit?speed=fast&unit=hour")

      # Default (and unknown values) stay per tick with clean links.
      for params <- [[], [unit: "week"]] do
        html = conn |> get("/help/population", params) |> html_response(200)
        refute html =~ "help-units-hour"
        assert html =~ ~s(href="/help/credit")
        refute html =~ ~s(href="/help/credit?unit=)
      end
    end

    test "every page has the unit switch, and set_unit patches the URL", %{conn: conn} do
      # A page without any rate still offers the switch.
      html = conn |> get("/help/housing") |> html_response(200)
      assert html =~ ~s(id="help-unit-toggle")
      assert html =~ ~s(href="/help/housing?unit=hour")

      {:ok, view, _} = live(conn, "/help/population?speed=fast")
      render_hook(view, "set_unit", %{"unit" => "hour"})
      assert_patch(view, "/help/population?speed=fast&unit=hour")
      assert render(view) =~ "help-units-hour"
    end

    test "?lang=fr localizes names", %{conn: conn} do
      html = conn |> get("/help/mobility", lang: "fr") |> html_response(200)
      assert html =~ "Liaison orbitale"
      assert html =~ ~s(href="/help/credit?lang=fr")
    end

    test "unknown slug is a 404", %{conn: conn} do
      assert_error_sent(404, fn -> get(conn, "/help/no-such-page") end)
    end
  end

  describe "GET /help/:catalog/:key" do
    test "renders a building page with its badge, card and generated sections", %{conn: conn} do
      html = conn |> get("/help/building/monument_dome") |> html_response(200)

      assert html =~ "Monolith — Manual"
      assert html =~ ~s(<span class="help-limit-badge" title="Can only build one per star system.">Unique</span>)
      assert html =~ ~s(<figure class="help-bcard" data-building="monument_dome">)
      assert html =~ ~s(<input type="radio" name="help-bcard-monument_dome" value="5">)
      assert html =~ ~s(<h2 id="levels">)
      refute html =~ ~s(<i class="help-icon")
    end

    test "the index links catalog pages on the two-segment route", %{conn: conn} do
      html = conn |> get("/help") |> html_response(200)
      assert html =~ ~s(href="/help/building/monument_dome")
      refute html =~ "building%2F"
    end

    test "a building missing from a speed says so, and an unknown key is a 404", %{conn: conn} do
      html = conn |> get("/help/building/hab_open", speed: "fast") |> html_response(200)
      assert html =~ "This building is not in Flash games."
      assert_error_sent(404, fn -> get(conn, "/help/building/no_such_building") end)
    end
  end
end
