defmodule Portal.CreateArticleLive do
  use Portal, :admin_live_view

  alias RC.Blog

  @impl true
  def mount(_params, session, socket) do
    {:ok, assign(socket, :current_user, RC.Guardian.resource_from_session(session))}
  end

  @impl true
  def handle_params(_params, _, socket) do
    categories =
      RC.Repo.all(RC.Blog.Category)
      |> Enum.map(fn cat -> {cat.name, cat.id} end)

    {:noreply, assign(socket, categories: categories)}
  end

  @impl true
  def handle_event("new", %{"post" => post}, socket) do
    post =
      post
      |> Map.put("language", "fr")
      # TODO
      |> Map.put("picture", "TODO")

    # Blog.Post.changeset/2 no longer casts :account_id (mass-assignment
    # hardening), so authorship has to be passed through Blog.create_post/2's
    # second argument. The previously-hardcoded `Map.put("account_id", 1)` in
    # the attrs payload was silently dropped by the changeset cast.
    account_id = socket.assigns.current_user.id

    case Blog.create_post(post, account_id) do
      {:ok, _} ->
        {:noreply, push_navigate(socket, to: Routes.live_path(socket, Portal.ArticlesLive))}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end
end
