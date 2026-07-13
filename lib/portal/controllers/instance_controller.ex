defmodule Portal.InstanceController do
  @moduledoc """

  The Instance controller.

  API:

  Creates an Instance:
      POST /instances, body: %{instance: instances_params, scenario_id: scenario_id}
  Get a single Instance:
      GET /instances/:iid
  Update an Instance:
      PUT /instances/:iid
  Delete an Instance:
      DELETE /instances/:iid
  Publish an Instance (to make it visible):
      PUT /instances/:iid/publish
  Start or restart an Instance, creates the supervisor and changes the state of the Registrations to `playing`:
      PUT /instances/:iid/start
  Pause an Instance, pauses the supervisor:
      PUT /instances/:iid/pause
  Resume an Instance, starts again the supervisor:
      PUT /instances/:iid/resume
  Finish an Instance, kills the supervisor if the previous instance's state was `running`:
      PUT /instances/:iid/finish
  Export replay (not verified):
      GET /instances/:iid/export-replay
  """
  use Portal, :controller

  alias RC.Instances

  require Logger

  action_fallback(Portal.FallbackController)

  def index(conn, params) do
    aid =
      if conn.private.guardian_default_resource.role == :admin,
        do: nil,
        else: conn.private.guardian_default_resource.id

    case Instances.list_instances(params, :count_registrations, aid) do
      {:ok, instances} ->
        conn
        |> Scrivener.Headers.paginate(instances)
        |> render("index.json", instances: instances)

      error ->
        error
    end
  end

  def publish(conn, %{"iid" => iid}) do
    aid = conn.private.guardian_default_resource.id

    with instance <- Instances.get_instance(iid),
         "created" = instance.state,
         {:ok, _updated_instance} <- Instances.publish_instance(instance, aid) do
      conn
      |> put_status(:ok)
      |> json(%{message: :instance_published})
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def start(conn, %{"iid" => iid} = params) do
    aid = conn.private.guardian_default_resource.id

    case Instances.get_instance_with_registration(iid) do
      nil ->
        {:error, :not_found}

      instance ->
        case instance.state do
          "open" ->
            do_fresh_start(conn, instance, aid)

          "not_running" ->
            do_restart(conn, instance, aid, confirm_fresh_start?(params))

          _other ->
            {:error, :invalid_state}
        end
    end
  end

  def restart(conn, %{"iid" => iid} = params) do
    aid = conn.private.guardian_default_resource.id

    case Instances.get_instance(iid) do
      nil ->
        {:error, :not_found}

      %{state: "not_running"} = instance ->
        do_restart(conn, instance, aid, confirm_fresh_start?(params))

      _instance ->
        {:error, :invalid_state}
    end
  end

  # First-ever launch of a published instance — there can be no snapshot, so
  # always build the world from the scenario model.
  defp do_fresh_start(conn, instance, aid) do
    with {:ok, :instantiated} <- Instance.Manager.create_from_model(instance, nil),
         {:ok, :started, _} <- Instance.Manager.call(instance.id, :start),
         {:ok, %{registrations_errors: registrations_errors_count}} <- Instances.start_instance(instance, aid) do
      conn
      |> put_status(:ok)
      |> json(%{message: :instance_started, registrations_errors: registrations_errors_count})
    else
      error -> error
    end
  end

  # Restart of a previously-running instance whose supervisor died (OOM,
  # node restart, manual destroy). Try the most recent snapshot first; only
  # rebuild from scratch if the admin has explicitly confirmed that no
  # progress should be preserved. See RC.Instances.restart_instance_from_snapshot/1.
  defp do_restart(conn, instance, aid, confirm_fresh_start) do
    case Instances.restart_instance_from_snapshot(instance) do
      {:ok, :restarted} ->
        {:ok, _updated_instance} = Instances.restart_instance(instance, aid)

        conn
        |> put_status(:ok)
        |> json(%{message: :instance_restarted})

      {:error, :no_snapshot} when confirm_fresh_start ->
        do_fresh_restart(conn, instance, aid)

      {:error, :no_snapshot} ->
        conn
        |> put_status(:ok)
        |> json(%{message: :fresh_start_required})

      {:error, :load_failed} ->
        conn
        |> put_status(503)
        |> json(%{message: :snapshot_load_failed})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_fresh_restart(conn, instance, aid) do
    with {:ok, :instantiated} <- Instance.Manager.create_from_model(instance, nil),
         {:ok, :started, _} <- Instance.Manager.call(instance.id, :start),
         {:ok, _updated_instance} <- Instances.restart_instance(instance, aid) do
      conn
      |> put_status(:ok)
      |> json(%{message: :instance_restarted, fresh_start: true})
    else
      error -> error
    end
  end

  defp confirm_fresh_start?(%{"confirm_fresh_start" => v}) when v in [true, "true", 1, "1"], do: true
  defp confirm_fresh_start?(_), do: false

  def finish(conn, %{"iid" => iid}) do
    aid = conn.private.guardian_default_resource.id

    with instance <- Instances.get_instance(iid),
         state when state in ["running", "not_running", "paused"] <- instance.state do
      message =
        if state in ["running", "paused"] do
          case Instance.Manager.destroy(instance.id) do
            {:ok, _} ->
              :instance_killed_and_finished

            {:error, reason} ->
              Logger.error("#{reason}")
              :instance_finished_with_errors
          end
        else
          :instance_finished
        end

      {:ok, instance} = Instances.close_instance(instance)
      {:ok, _updated_instance} = Instances.finish_instance(instance, aid)

      conn
      |> put_status(:ok)
      |> json(%{message: message})
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def pause(conn, %{"iid" => iid}) do
    aid = conn.private.guardian_default_resource.id

    with instance <- Instances.get_instance(iid),
         "running" = instance.state,
         {:ok, :stopped, _} <- Instance.Manager.call(instance.id, :stop),
         {:ok, _updated_instance} <- Instances.pause_instance(instance, aid) do
      conn
      |> put_status(:ok)
      |> json(%{message: :instance_paused})
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def resume(conn, %{"iid" => iid}) do
    aid = conn.private.guardian_default_resource.id

    with instance <- Instances.get_instance(iid),
         "paused" = instance.state,
         {:ok, :started, _} <- Instance.Manager.call(instance.id, :start),
         {:ok, _updated_instance} <- Instances.resume_instance(instance, aid) do
      conn
      |> put_status(:ok)
      |> json(%{message: :instance_resumed})
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def create(conn, %{"instance" => instance_params, "scenario_id" => scenario_id}) do
    aid = conn.private.guardian_default_resource.id

    with scenario when not is_nil(scenario) <- RC.Scenarios.get_scenario(scenario_id),
         {:ok, %{instance: instance}} <- Instances.create_instance(instance_params, scenario, aid) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", Routes.instance_path(conn, :show, instance))
      |> render("show.json", instance: instance)
    else
      nil ->
        conn
        |> put_status(404)
        |> json(%{message: :scenario_not_found})

      error ->
        error
    end
  end

  def show(conn, %{"iid" => iid}) do
    case Instances.get_instance(iid) do
      nil -> {:error, :not_found}
      instance -> render(conn, "show.json", instance: instance)
    end
  end

  @doc """
  Public news feed for the instance — the last 5 global news rows.
  Inlined as a simple json/2 response: news rows have a stable
  `{id, key, data, inserted_at}` shape that the SPA's `<NewsTicker>`
  renders client-side using i18n templates keyed by `key`.

  The auth pipeline already restricts this to viewers who can see
  `GET /instances/:iid`, and the rows themselves contain no
  faction-private data (News.Server only writes globally-safe
  payloads to PlayerEvent — faction-private detail goes to
  PlayerReport in a separate fan-out, not yet wired in the seed PR).
  """
  def news(conn, %{"iid" => iid}) do
    case Instances.get_instance(iid) do
      nil ->
        {:error, :not_found}

      instance ->
        events =
          instance.id
          |> RC.PlayerEvents.get_public_news(5)
          |> Enum.map(fn e ->
            %{
              id: e.id,
              key: e.key,
              data: decode_data(e.data),
              inserted_at: e.inserted_at
            }
          end)

        json(conn, %{news: events})
    end
  end

  @doc """
  Cross-instance public news — the last 5 news rows across all public
  instances, tagged with the source instance's name and id. Powers the
  scrolling marquee on the /portal/play/:speed game lists.
  """
  def recent_news(conn, _params) do
    events =
      RC.PlayerEvents.get_recent_public_news(5)
      |> Enum.map(fn {e, instance_name} ->
        %{
          id: e.id,
          key: e.key,
          data: decode_data(e.data),
          inserted_at: e.inserted_at,
          instance_id: e.instance_id,
          instance_name: instance_name
        }
      end)

    json(conn, %{news: events})
  end

  # PlayerEvent.data is a JSON-encoded string; decode here so the SPA
  # gets a real object rather than a string-of-JSON.
  defp decode_data(nil), do: %{}

  defp decode_data(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  def update(conn, %{"iid" => iid, "instance" => instance_params}) do
    case Instances.get_instance(iid) do
      nil ->
        {:error, :not_found}

      instance ->
        # user_update_instance uses an allow-list changeset that strips
        # :state (state-machine bypass) and :account_id (ownership transfer).
        case Instances.user_update_instance(instance, instance_params) do
          {:ok, instance} -> render(conn, "show.json", instance: instance)
          error -> error
        end
    end
  end

  def delete(conn, %{"iid" => iid}) do
    instance = Instances.get_instance(iid)

    cond do
      instance == nil ->
        {:error, :not_found}

      instance.state in ["created", "open", "not_running", "ended"] ->
        with {:ok, %Instances.Instance{}} <- Instances.delete_instance(instance) do
          send_resp(conn, :no_content, "")
        end

      true ->
        conn
        |> put_status(403)
        |> json(%{message: :bad_instance_state_for_delete})
    end
  end
end
