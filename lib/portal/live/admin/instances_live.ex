defmodule Portal.InstancesLive do
  use Portal, :admin_live_view

  require Logger

  alias Instance.Manager
  alias RC.Instances
  alias RC.Instances.Instance

  @impl true
  def mount(_params, session, socket) do
    socket = assign(socket, current_user: RC.Guardian.resource_from_session(session))
    {:ok, assign(socket, %{filters: Instances.Instance, show_filters: false})}
  end

  @impl true
  def handle_params(params, _, socket) do
    params = Map.put(%{}, "page", Map.get(params, "page", nil))
    assigns = get_and_assign_page(params)

    instances_to_fix =
      RC.Instances.update_instances_state_if_needed()
      |> Enum.map(fn %{id: id} -> id end)

    assigns = Keyword.merge(assigns, instances_to_fix: instances_to_fix)
    {:noreply, assign(socket, assigns)}
  end

  def handle_event("filter", %{"Elixir.RC.Instances.Instance" => filters} = params, socket) do
    params = Map.put(%{}, "page", Map.get(params, "page", nil))

    filters =
      Enum.reduce(filters, %{}, fn {key, val}, acc ->
        case val do
          "" -> acc
          val -> Map.put(acc, key, val)
        end
      end)

    assigns = Map.merge(params, filters) |> get_and_assign_page()
    {:noreply, assign(socket, assigns)}
  end

  @impl true
  def handle_event("fix_instances", _params, socket) do
    RC.Instances.update_instances_state_if_needed(true)
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_filters", _params, socket) do
    {:noreply, assign(socket, show_filters: !socket.assigns.show_filters)}
  end

  @impl true
  def handle_event("force_end", %{"iid" => iid}, socket) do
    account_id = socket.assigns.current_user.id

    with %Instance{} = instance <- Instances.get_instance(iid),
         :ok <- maybe_destroy_supervisor(instance),
         {:ok, instance} <- Instances.close_instance(instance),
         {:ok, instance} <- Instances.finish_instance(instance, account_id) do
      socket =
        socket
        |> put_flash(:info, gettext("Instance %{name} ended", name: instance.name))
        |> refresh_instances()

      {:noreply, socket}
    else
      err ->
        Logger.error("force_end failed for instance #{iid}: #{inspect(err)}")
        {:noreply, put_flash(socket, :error, gettext("Failed to end instance"))}
    end
  end

  defp maybe_destroy_supervisor(%Instance{supervisor_status: :not_instantiated}), do: :ok

  defp maybe_destroy_supervisor(%Instance{id: id}) do
    case Manager.destroy(id) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp refresh_instances(socket) do
    params = %{"page" => socket.assigns.page_number}
    assign(socket, get_and_assign_page(params))
  end

  defp get_and_assign_page(params) do
    %{
      entries: entries,
      page_number: page_number,
      page_size: page_size,
      total_entries: total_entries,
      total_pages: total_pages
    } =
      case Instances.list_instances_admin(params) do
        {:ok, result} ->
          result

        _result ->
          %{
            entries: [],
            page_number: 0,
            page_size: 0,
            total_entries: 0,
            total_pages: 0
          }
      end

    [
      instances: entries,
      page_number: page_number,
      page_size: page_size,
      total_entries: total_entries,
      total_pages: total_pages
    ]
  end
end
