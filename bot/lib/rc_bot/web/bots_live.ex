defmodule RcBot.Web.BotsLive do
  @moduledoc """
  Driver dashboard. Shows the state of THIS driver's orchestrator —
  which bots are running, when each next wakes, local + global pause
  state — and lets the operator pause/resume this driver.

  Refreshes every second via `Process.send_after(self(), :tick, 1000)`.

  ## Actor model

  This is the **driver** view. It runs alongside the orchestrator in
  the same harness OTP app and exposes only local state + controls. The
  rc server's `/admin/bots` is the **supervisor** view — bot inventory,
  assignments, audit, global kill switch. The two are distinct UIs with
  distinct concerns.

  See `RcBot.Orchestrator` docs for the two-flag model: a session only
  spawns when (a) this driver is locally enabled AND (b) the rc server's
  global kill switch is PERMITTED.
  """

  use RcBot.Web, :live_view

  @refresh_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_tick()

    {:ok, assign(socket, refresh_status(%{}))}
  end

  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, assign(socket, refresh_status(socket.assigns))}
  end

  @impl true
  def handle_event("pause", _params, socket) do
    :ok = RcBot.Orchestrator.pause()
    {:noreply, assign(socket, refresh_status(socket.assigns))}
  end

  def handle_event("resume", _params, socket) do
    :ok = RcBot.Orchestrator.resume()
    {:noreply, assign(socket, refresh_status(socket.assigns))}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @refresh_ms)

  defp refresh_status(prev) do
    case orchestrator_status() do
      {:ok, status} ->
        %{
          status: status,
          target: target_http(),
          orchestrator_up: true,
          last_error: nil
        }

      {:error, reason} ->
        %{
          status: prev[:status],
          target: target_http(),
          orchestrator_up: false,
          last_error: reason
        }
    end
  end

  defp orchestrator_status do
    try do
      {:ok, RcBot.Orchestrator.status()}
    catch
      :exit, reason -> {:error, inspect(reason)}
    end
  end

  defp target_http do
    Application.get_env(:rc_bot, :target_http, "<unset>")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>RcBot driver</h1>
    <p class="muted">
      Target: <span class="target"><%= @target %></span>
    </p>

    <%= if not @orchestrator_up do %>
      <div class="banner banner-err">
        <div>
          <strong>Orchestrator is not running.</strong>
          <span class="muted">— start it with <code>RcBot.Orchestrator.start_link([])</code> in iex, or set <code>autostart_fleet: true</code> in config.</span>
        </div>
      </div>
      <%= if @last_error do %><p class="muted">Reason: <code><%= @last_error %></code></p><% end %>
    <% else %>
      <%= driver_state_banner(assigns) %>
      <%= global_state_banner(assigns) %>

      <h2>Bots</h2>
      <%= if @status && Enum.any?(@status.bots) do %>
        <table>
          <thead>
            <tr>
              <th>Bot</th>
              <th>Instance</th>
              <th>State</th>
              <th>PID</th>
            </tr>
          </thead>
          <tbody>
            <%= for bot <- @status.bots do %>
              <tr>
                <td><%= bot.bot_id %></td>
                <td>#<%= bot.instance_id %></td>
                <td>
                  <%= if bot.running do %>
                    <span class="badge badge-ok">running</span>
                  <% else %>
                    <span class="badge badge-warn">idle</span>
                  <% end %>
                </td>
                <td class="muted"><%= inspect(bot.session_pid) %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% else %>
        <p class="muted">No bots in this driver's roster.</p>
      <% end %>

      <h2>Schedule</h2>
      <pre style="background: #fafafa; padding: 12px; border: 1px solid #eee; font-size: 0.85em;"><%= inspect(@status && @status.schedule, pretty: true) %></pre>
    <% end %>

    <p class="muted" style="margin-top: 32px;">
      This page is the <strong>driver</strong> view — it controls only this harness instance.
      The supervisor view (bot inventory, assignments, audit) lives on the rc server at <code>/admin/bots</code>.
    </p>
    """
  end

  defp driver_state_banner(assigns) do
    paused = assigns.status && assigns.status.locally_paused

    assigns =
      Map.merge(assigns, %{
        paused: paused,
        cls: if(paused, do: "banner banner-warn", else: "banner banner-ok")
      })

    ~H"""
    <div class={@cls}>
      <div>
        <strong>This driver:</strong>
        <%= if @paused do %>
          <span class="badge badge-warn">PAUSED</span>
          <span class="muted">— in-flight sessions complete, no new ones spawn</span>
        <% else %>
          <span class="badge badge-ok">RUNNING</span>
          <span class="muted">— spawning sessions on schedule (subject to global)</span>
        <% end %>
      </div>
      <%= if @paused do %>
        <button phx-click="resume">Resume this driver</button>
      <% else %>
        <button phx-click="pause" data-confirm="Pause this driver?">Pause this driver</button>
      <% end %>
    </div>
    """
  end

  defp global_state_banner(assigns) do
    permitted = assigns.status && assigns.status.globally_permitted

    assigns =
      Map.merge(assigns, %{
        permitted: permitted,
        cls: if(permitted, do: "banner banner-ok", else: "banner banner-err")
      })

    ~H"""
    <div class={@cls}>
      <div>
        <strong>Global fleet (set on rc server):</strong>
        <%= if @permitted do %>
          <span class="badge badge-ok">PERMITTED</span>
          <span class="muted">— drivers may run</span>
        <% else %>
          <span class="badge badge-err">DENIED</span>
          <span class="muted">— fleet-wide kill switch is on; no driver can spawn sessions</span>
        <% end %>
      </div>
      <span class="muted">read-only here — flip from the supervisor view</span>
    </div>
    """
  end
end
