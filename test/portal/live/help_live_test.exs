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

    test "search works live", %{conn: conn} do
      {:ok, view, _} = live(conn, "/help")
      html = render_change(view, "search", %{"q" => "taxes"})
      assert html =~ "Results for"
      assert html =~ ~s(href="/help/taxes")
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
      assert html =~ ~s(<a href="/help/taxes" class="help-ref" data-help="taxes">taxes</a>)
      assert html =~ "Related"
    end

    test "?speed= switches the variant and is kept in links", %{conn: conn} do
      html = conn |> get("/help/population", speed: "fast") |> html_response(200)
      assert html =~ "Numbers shown for <strong>Flash</strong>"
      assert html =~ ~s(href="/help/taxes?speed=fast")
      # Flash has 0 base defense per population; Legacy has 0.15.
      assert html =~ "adds 0 defense"
      refute html =~ "adds 0.15 defense"
    end

    test "?lang=fr localizes names", %{conn: conn} do
      html = conn |> get("/help/mobility", lang: "fr") |> html_response(200)
      assert html =~ "Liaison orbitale"
      assert html =~ ~s(href="/help/taxes?lang=fr")
    end

    test "unknown slug is a 404", %{conn: conn} do
      assert_error_sent(404, fn -> get(conn, "/help/no-such-page") end)
    end
  end
end
