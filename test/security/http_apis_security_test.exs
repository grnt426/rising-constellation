defmodule RC.Security.HttpApisTest do
  @moduledoc """
  Regression tests for the Stage 5 Bucket-1 and Bucket-2 fixes:

  Bucket 1 — clear safe defaults:
    * #B1.1  Scrivener `max_page_size: 200` clamps `?page_size=` server-side.
    * #B1.2  Account password validate_length(min: 8, max: 128).
    * #B1.3  Upload.name validate_length(max: 200) on both Upload and ImageUpload.
    * #B1.4  RC.DisplayName.validate_display_name rejects control / bidi /
             format codepoints on Account/Profile/Conversation/Folder/
             Instance/BlogPost name+title.
    * #B1.6  RC.Markdown.render_inline upgrades protocol-relative URLs
             (`href="//x"`) to absolute HTTPS so they're not visually
             indistinguishable from same-origin paths in `content_raw`.

  Bucket 2 — generous limits with changeset-style errors:
    * #B2.1  BlogPost.content_raw validate_length(max: 200_000).
    * #B2.2  MessengerController.create_conv_group rejects
             `profiles_ids` lists over 100 entries with a 422 +
             `%{errors: %{profiles_ids: [...]}}` body.
  """
  use Portal.APIConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import RC.Fixtures

  alias RC.Accounts
  alias RC.Accounts.Account
  alias RC.Accounts.Profile
  alias RC.DisplayName
  alias RC.Markdown
  alias RC.Repo

  describe "Stage 5 #B1.1 — Scrivener max_page_size clamps ?page_size=" do
    test "Repo Scrivener config sets max_page_size to 200" do
      # The clamp lives inside Scrivener.Config; we verify it via the
      # documented Scrivener API. Building a tiny query and paginating
      # with an absurd page_size proves the server-side clamp.
      query = from(a in Account, where: false, select: a.id)

      page = Repo.paginate(query, %{"page_size" => "10000000"})

      assert page.page_size <= 200,
             "expected Scrivener to clamp page_size; got #{page.page_size}"
    end
  end

  describe "Stage 5 #B1.2 — password length bounds" do
    test "password shorter than 8 chars is rejected" do
      attrs = Map.put(account_valid_user_attrs(), :password, "short")

      assert {:error, changeset} = Accounts.create_account(attrs)
      assert %{password: [msg | _]} = errors_on(changeset)
      assert msg =~ "should be at least 8 character"
    end

    test "password longer than 128 chars is rejected (Argon2 DoS)" do
      attrs = Map.put(account_valid_user_attrs(), :password, String.duplicate("A", 1_000))

      assert {:error, changeset} = Accounts.create_account(attrs)
      assert %{password: [msg | _]} = errors_on(changeset)
      assert msg =~ "should be at most 128 character"
    end

    test "password of legitimate length is accepted" do
      attrs = Map.put(account_valid_user_attrs(), :password, "good-enough-password-123")
      assert {:ok, _account} = Accounts.create_account(attrs)
    end
  end

  describe "Stage 5 #B1.3 — Upload.name length bound" do
    test "Upload changeset rejects names over 200 chars" do
      attrs = %{
        name: String.duplicate("A", 1_000),
        account_id: 1,
        content_type: "png"
      }

      changeset = RC.Uploader.Upload.changeset(%RC.Uploader.Upload{}, attrs)
      assert %{name: [msg | _]} = errors_on(changeset)
      assert msg =~ "should be at most 200 character"
    end
  end

  describe "Stage 5 #B1.4 — DisplayName validator (Unicode/bidi/control rejection)" do
    test "plain ASCII names pass" do
      changeset = make_profile_changeset(%{"name" => "Alice"})
      assert changeset.valid?
    end

    test "leading/trailing whitespace is trimmed (not rejected)" do
      changeset = make_profile_changeset(%{"name" => "  Alice  "})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :name) == "Alice"
    end

    test "U+202E RIGHT-TO-LEFT OVERRIDE is rejected" do
      # Build the bad codepoint at runtime so the source file itself
      # stays free of bidi overrides.
      rtl_override = <<0xE2, 0x80, 0xAE>>
      name = "Alice" <> rtl_override <> "ecilA"

      changeset = make_profile_changeset(%{"name" => name})
      refute changeset.valid?
      assert %{name: [msg | _]} = errors_on(changeset)
      assert msg =~ "disallowed"
    end

    test "U+200B ZERO WIDTH SPACE is rejected" do
      zwsp = <<0xE2, 0x80, 0x8B>>
      name = "Ali" <> zwsp <> "ce"

      changeset = make_profile_changeset(%{"name" => name})
      refute changeset.valid?
    end

    test "C0 control bytes (newline, tab) are rejected" do
      assert {:error, _} = run_validator("Alice\nDoe")
      assert {:error, _} = run_validator("Alice\tDoe")
      assert {:error, _} = run_validator("AliceDoe")
    end

    # `""` and `"   "` are normalised away by Ecto.Changeset.cast before
    # this validator ever runs (Ecto trims string inputs and treats them
    # as empty_values). Detecting "blank" is the responsibility of
    # `validate_required`, which every real consumer pairs us with — so
    # the validator's contract is "reject disallowed codepoints in
    # non-empty strings", which is what the other tests in this describe
    # block cover.

    defp run_validator(value) do
      changeset =
        {%{}, %{name: :string}}
        |> Ecto.Changeset.cast(%{"name" => value}, [:name])
        |> DisplayName.validate_display_name(:name)

      if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
    end

    defp make_profile_changeset(attrs) do
      Profile.changeset(%Profile{}, Map.merge(%{"avatar" => "x", "account_id" => 1}, attrs))
    end
  end

  describe "Stage 5 #B1.6 — Markdown sanitizer upgrades protocol-relative URLs" do
    test "[label](//harvest.example) becomes <a href=\"https://harvest.example\">" do
      html = Markdown.render_inline("[label](//harvest.example)")
      assert html =~ "https://harvest.example"
      refute html =~ ~s|href="//harvest|
    end

    test "well-formed https links are unchanged" do
      html = Markdown.render_inline("[label](https://legit.example/path)")
      assert html =~ ~s|https://legit.example/path|
    end

    test "javascript: scheme is stripped by the sanitizer (sanity)" do
      html = Markdown.render_inline("[click](javascript:alert(1))")
      refute html =~ "javascript:"
    end
  end

  describe "Stage 5 #B2.1 — BlogPost.content_raw 200 KB cap" do
    test "content_raw over 200 KB is rejected with a changeset error" do
      attrs = %{
        "title" => "ok",
        "picture" => "x",
        "content_raw" => String.duplicate("a", 200_001),
        "summary_raw" => "x",
        "language" => "en",
        "category_id" => 1
      }

      changeset = RC.Blog.Post.changeset(%RC.Blog.Post{}, attrs)
      assert %{content_raw: [msg | _]} = errors_on(changeset)
      assert msg =~ "should be at most 200000 character"
    end

    test "100 KB content_raw is accepted (well within the limit)" do
      attrs = %{
        "title" => "ok",
        "picture" => "x",
        "content_raw" => String.duplicate("a", 100_000),
        "summary_raw" => "x",
        "language" => "en",
        "category_id" => 1
      }

      changeset = RC.Blog.Post.changeset(%RC.Blog.Post{}, attrs)
      # content_raw passes its length check (other required fields may
      # still error in isolation — what we care about here is :content_raw
      # has no length error).
      refute Keyword.has_key?(changeset.errors, :content_raw)
    end
  end

  describe "Stage 5 #B2.2 — profiles_ids 100-entry cap" do
    test "list of 101 entries returns 422 with field-named changeset error",
         %{conn: conn} do
      user = fixture(:user) |> activate!()
      {:ok, profile} = make_profile(user)

      huge_list = Enum.to_list(1..101)

      response =
        conn
        |> login(user)
        |> post(
          Routes.messenger_path(conn, :create_conv_group, profile.id),
          %{
            "profiles_ids" => huge_list,
            "content_raw" => "hi",
            "name" => "spam"
          }
        )

      assert response.status == 422
      body = json_response(response, 422)
      assert %{"errors" => %{"profiles_ids" => [_msg]}} = body
    end

    test "list of 50 entries is accepted (well within the limit)",
         %{conn: conn} do
      user = fixture(:user) |> activate!()
      {:ok, profile} = make_profile(user)

      # The function-clause guard accepts 50; the downstream creation
      # path may still error on something else (e.g. nonexistent profile
      # ids → foreign-key violation). What we assert is "it is NOT
      # rejected by our profiles_ids guard with status 422", i.e. the
      # request gets past the cap.
      ok_list = Enum.to_list(1..50)

      response =
        conn
        |> login(user)
        |> post(
          Routes.messenger_path(conn, :create_conv_group, profile.id),
          %{
            "profiles_ids" => ok_list,
            "content_raw" => "hi",
            "name" => "ok"
          }
        )

      # The status will not be 422 with our :profiles_ids error.
      # It might be 400/500 for the FK violation on fake ids, but it
      # must NOT be our cap-rejection.
      case response.status do
        422 ->
          body = json_response(response, 422)

          refute Map.has_key?(body["errors"] || %{}, "profiles_ids"),
                 "50-entry list should not hit the cap"

        _ ->
          :ok
      end
    end
  end

  defp activate!(account) do
    {:ok, a} = Ecto.Changeset.change(account, status: :active) |> Repo.update()
    a
  end

  defp make_profile(account) do
    Repo.insert(
      Profile.changeset(%Profile{}, %{
        avatar: "x",
        name: "p-#{:erlang.unique_integer([:positive])}",
        account_id: account.id
      })
    )
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
