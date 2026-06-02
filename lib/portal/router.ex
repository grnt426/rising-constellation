defmodule Portal.Router do
  use Portal, :router

  require EnvOnly

  import Phoenix.LiveView.Router
  import Phoenix.LiveDashboard.Router

  EnvOnly.dev do
    require Terraform
    Terraform.__using__(terraformer: Portal.Plug.DevProxy)
  end

  pipeline :auth do
    plug(:fetch_session)
    plug(Portal.Plug.AuthAccessPipeline)
  end

  # `:auth_api` — currently identical to `:auth` (cookie + bearer). The
  # plumbing for a Bearer-only API exists in Portal.Plug.AuthApiPipeline;
  # switching scopes to use it cleanly eliminates the CSRF surface on
  # `/api/*`. Deferred until the SPA's axios instance captures the JWT
  # from the login response and sends it as `Authorization: Bearer ...`
  # in web mode (today only the Steam path does this — see
  # front/src/plugins/axios.js and the IS_STEAM gate). Until then the
  # session cookie's SameSite=Lax attribute + Corsica Origin allow-list
  # are the active CSRF mitigations.
  pipeline :auth_api do
    plug(:fetch_session)
    plug(Portal.Plug.AuthAccessPipeline)
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :browser_public do
    plug(:put_root_layout, {Portal.PublicLayoutView, :root})
  end

  pipeline :browser_admin do
    plug(:put_root_layout, {Portal.AdminLayoutView, :root})
    plug(Guardian.Plug.EnsureAuthenticated)
    plug(Portal.Plug.Authorization, :admin)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :authenticated_api do
    plug(Guardian.Plug.EnsureAuthenticated)
    plug(:accepts, ["json"])
  end

  pipeline :admin_authorization do
    plug(Portal.Plug.Authorization, :admin)
  end

  pipeline :own_resource_authorization do
    plug(Portal.Plug.Authorization, :own_resource)
  end

  pipeline :group_resource_authorization do
    plug(Portal.Plug.Authorization, :group_resource)
  end

  pipeline :conversation_admin_authorization do
    plug(Portal.Plug.Authorization, :conversation_admin)
  end

  pipeline :conversation_member_authorization do
    plug(Portal.Plug.Authorization, :conversation_member)
  end

  scope "/", Portal do
    pipe_through([:auth, :browser, :browser_public])

    live("/", LandingLive)
    live("/press-kit", PressKitLive)
    live("/cgu", CGULive)
    live("/login", LoginLive)
    live("/signup", SignupLive)
    live("/forgotten-password", ForgottenPasswordLive)
    live("/reset-password", ResetPasswordLive)
    live("/bind", WebBindLive)
  end

  scope "/admin", Portal do
    pipe_through([:auth, :browser, :browser_admin, :admin_authorization])

    # Stage 6 Cluster A fix. Without this `live_session`/`on_mount` hook
    # the router's `:admin_authorization` plug only runs on the initial
    # HTTP GET — every subsequent WebSocket reconnect and `handle_event`
    # frame trusts the still-open socket regardless of the account's
    # current role/status. Portal.AdminAuth.on_mount/4 re-resolves the
    # account from the session on every mount and halts the LiveView
    # whenever role != :admin or status != :active.
    live_session :admin, on_mount: {Portal.AdminAuth, :ensure_admin} do
      live("/", AdminLive)
      live("/accounts", AccountsLive)
      live("/bots", BotsLive)
      live("/accounts/:uid", AccountLive)
      live("/groups", GroupsLive)
      live("/instances", InstancesLive)
      live("/instances/:iid", InstanceLive)
      live("/instances/replay/:iid", ReplayLive)
      live("/instances/charts/:iid", ChartsLive)
      live("/instances/replay/:iid/:profile", ReplayLive)
      live("/blog/articles", ArticlesLive)
      live("/blog/article/new", CreateArticleLive)
      live("/blog/article/:pid", EditArticleLive)
      live("/blog/categories", CategoriesLive)
      live("/logs", LogsLive)
      live("/maintenance", MaintenanceLive)
      live("/settings", SettingsLive)
      live("/nodes", NodesLive)
      live("/maps", MapsLive)
      live("/maps/:mid", MapLive)
      live("/scenarios", ScenariosLive)
      live("/scenarios/:sid", ScenarioLive)
      live("/profiles", ProfilesLive)
      live("/profiles/:pid", ProfileLive)
      live("/keys", KeysLive)
    end

    # Phoenix LiveDashboard creates its own internal live_session, so we
    # can't wrap it in ours — we pass the `on_mount` directly. Stage 6
    # H10 demonstrated that the dashboard's Processes/Settings/EctoStats
    # pages let a residual admin socket kill BEAM processes and dump SQL
    # stats even after the role downgrade.
    live_dashboard("/live",
      metrics: Portal.Telemetry,
      ecto_repos: [RC.Repo],
      on_mount: [{Portal.AdminAuth, :ensure_admin}]
    )
  end

  scope "/api", Portal do
    pipe_through([:api])

    post("/accounts/bind", AccountController, :bind)
    get("/maintenance", MaintenanceController, :maintenance)
    get("/health", MaintenanceController, :healthcheck)
    get("/version", MaintenanceController, :backend_version)
  end

  scope "/api", Portal do
    pipe_through([:auth_api, :api])

    post("/accounts", AccountController, :create)
    post("/accounts/validate", AccountController, :validate)
    post("/accounts/validate-update", AccountController, :validate_update)
    post("/accounts/request-password-reset", AccountController, :send_password_reset)
    post("/accounts/request-email-verification", AccountController, :send_email_verification)
    post("/accounts/reset-password", AccountController, :reset_password)
    post("/auth/identity/callback", AuthenticationController, :identity_callback)
    post("/logout", AuthenticationController, :logout)

    post("/steam/ticket", SteamController, :ticket_auth)

    # TODO: unused routes
    get("/blog/posts", Blog.PostController, :index)
    get("/blog/posts/:bpid", Blog.PostController, :show)
    get("/blog/posts/:bpid/comments", Blog.CommentController, :index)
    get("/blog/categories", Blog.CategoryController, :index)
  end

  scope "/api", Portal do
    pipe_through([:auth_api, :authenticated_api])

    get("/account", AccountController, :get_own_account)
    post("/accounts/settings", AccountController, :update_settings)
    get("/profile/search/:query", ProfileController, :search)
    get("/profile/search/:iid/:query", ProfileController, :search_instance)

    get("/standings", RankingsController, :standings)

    post("/instances", InstanceController, :create)
    get("/instances", InstanceController, :index)

    # Bot harness lifecycle reports. Controller does its own `is_bot`
    # gate — sitting in the plain :authenticated_api scope is intentional
    # so the bot can hit it with just a Bearer JWT, no extra plug surface.
    post("/bot-events", BotEventController, :create)

    post("/blog/posts/:bpid/comments", Blog.CommentController, :create)

    get("/folders", FolderController, :index)
    get("/folders/:fid", FolderController, :show)

    # `likes`/`dislikes`/`favorites` go to system-reserved folders scoped
    # internally to the caller's account_id — no :fid in the path, so
    # they stay in :authenticated_api (no per-folder ownership to check).
    post("/scenarios/:sid/folders/likes", FolderController, :like)
    post("/scenarios/:sid/folders/dislikes", FolderController, :dislike)
    post("/scenarios/:sid/folders/favorites", FolderController, :favorite)

    post("/maps/:mid/folders/likes", FolderController, :like)
    post("/maps/:mid/folders/dislikes", FolderController, :dislike)
    post("/maps/:mid/folders/favorites", FolderController, :favorite)

    resources("/scenarios", ScenarioController, only: [:show, :index], param: "sid")
    resources("/maps", MapController, only: [:show, :index], param: "mid")
    post("/maps/preview-edges", MapController, :preview_edges)
    get("/profiles/:pid", ProfileController, :show)

    get("/data", DataController, :all)
    get("/data/:module", DataController, :all_in_module)
    get("/name/:module/:size", DataController, :random_name)

    post("/run-fight", FightController, :run)
  end

  scope "/api", Portal do
    pipe_through([:auth_api, :authenticated_api, :conversation_admin_authorization])

    put("/messenger/:pid/:cid/add/:profile_to_add", MessengerController, :add_profile)
    delete("/messenger/:pid/:cid/remove/:profile_to_remove", MessengerController, :remove_profile)
  end

  scope "/api", Portal do
    pipe_through([:auth_api, :authenticated_api, :own_resource_authorization])

    get("/messenger/:pid", MessengerController, :index)
    get("/messenger/:pid/instance/:iid", MessengerController, :index_by_instance)

    post("/messenger/new/:pid/:iid/group", MessengerController, :create_conv_group)
    post("/messenger/new/:pid/group", MessengerController, :create_conv_group)
    post("/messenger/new/:pid/:iid", MessengerController, :send_or_create_conv)
    post("/messenger/new/:pid", MessengerController, :send_or_create_conv)
  end

  scope "/api", Portal do
    pipe_through([:auth_api, :authenticated_api, :conversation_member_authorization])

    get("/messenger/:pid/:cid", MessengerController, :index_messages)
    post("/messenger/:pid/:cid", MessengerController, :send_to_conv)
  end

  # NOTE: this scope is declared BEFORE the `/instances/:iid/...` group_resource
  # scope below so that the literal `tutorial` segment doesn't get bound to
  # :iid by the earlier router patterns. Otherwise `/instances/tutorial/...`
  # routes to `:join` (with iid="tutorial") instead of `:create_and_join_tutorial`.
  scope "/api", Portal do
    pipe_through([:auth_api, :authenticated_api, :own_resource_authorization])

    get("/instances/tutorial/game/start/:pid", GameController, :create_and_join_tutorial)
  end

  scope "/api", Portal do
    pipe_through([:auth_api, :authenticated_api, :group_resource_authorization])

    get("/instances/:iid", InstanceController, :show)
    get("/instances/:iid/game/start/:token", GameController, :join)
    # delete("/instances/:iid/faction/:fid", RegistrationController, :unregister)

    get("/uploads", UploadController, :index)
    post("/uploads", UploadController, :upload)
    # DELETE /uploads/:upid moved to the :own_resource scope so per-upload
    # ownership is enforced — blog-writer membership alone used to grant
    # any writer the ability to delete any user's uploads.

    get("/instances/:iid/registrations", RegistrationController, :index_by_instance)

    # TODO: unused routes
    get("/blog/posts/:bpid/raw", Blog.PostController, :show_raw)
    # PUT/DELETE /blog/posts/:bpid moved to the :own_resource scope so
    # per-post ownership is enforced. POST stays here (blog-writers
    # membership is the right gate for "may post a new article").
    post("/blog/posts", Blog.PostController, :create)
    resources("/blog/categories", Blog.CategoryController, except: [:index], param: "bcid")
  end

  scope "/api", Portal do
    pipe_through([:auth_api, :authenticated_api, :own_resource_authorization])

    put("/accounts/:aid", AccountController, :update_restricted)
    put("/accounts/:aid/bind", AccountController, :request_web_bind)
    resources("/accounts", AccountController, only: [:show, :delete], param: "aid")

    post("/accounts/:aid/profiles", ProfileController, :create)
    get("/accounts/:aid/profiles", ProfileController, :index_by_account)
    resources("/profiles", ProfileController, only: [:update, :delete], param: "pid")

    get("/logs/:aid", LogController, :index_by_account)

    resources("/blog/comments", Blog.CommentController, only: [:show, :update, :delete], param: "bcid")

    post("/registrations/profile/:pid", RegistrationController, :join)
    put("/registrations/profile/:pid/cancel", RegistrationController, :unjoin)
    put("/registrations/profile/:pid/kill", RegistrationController, :kill)
    put("/registrations/profile/:pid/resign", RegistrationController, :resign)

    put("/instances/:iid/start", InstanceController, :start)
    put("/instances/:iid/publish", InstanceController, :publish)
    put("/instances/:iid/finish", InstanceController, :finish)
    put("/instances/:iid/pause", InstanceController, :pause)
    put("/instances/:iid/resume", InstanceController, :resume)
    put("/instances/:iid/restart", InstanceController, :restart)
    resources("/instances", InstanceController, only: [:update, :delete], param: "iid")

    # NOTE: `GET /instances/tutorial/game/start/:pid` is declared in a
    # dedicated own_resource scope earlier in this router so it wins the
    # route match against `/instances/:iid/game/start/:token`.

    # Per-folder mutations gated by `:fid` ownership (new own_resource clause).
    put("/scenarios/:sid/folders/:fid", FolderController, :insert)
    delete("/scenarios/:sid/folders/:fid", FolderController, :remove)
    put("/maps/:sid/folders/:fid", FolderController, :insert)
    delete("/maps/:sid/folders/:fid", FolderController, :remove)

    # Upload deletion: per-upload ownership via `:upid` (new own_resource
    # clause). Was previously on :group_resource = any blog-writer can
    # delete any user's upload.
    delete("/uploads/:upid", UploadController, :delete)

    # Per-post blog mutations gated by `:bpid` ownership (new own_resource
    # clause). POST stays on group_resource (blog-writers membership) below.
    put("/blog/posts/:bpid", Blog.PostController, :update)
    delete("/blog/posts/:bpid", Blog.PostController, :delete)
  end

  scope "/api", Portal do
    pipe_through([:auth_api, :authenticated_api, :admin_authorization])

    resources("/scenarios", ScenarioController, except: [:show, :index], param: "sid")
    resources("/maps", MapController, except: [:show, :index], param: "mid")

    resources("/groups", GroupController, only: [:index, :show, :create, :update, :delete], param: "gid")
    post("/groups/:gid/instance", GroupController, :add_instances)
    post("/groups/:gid/account", GroupController, :add_accounts)
    delete("/groups/:gid/account/:aid", GroupController, :remove_account)
    delete("/groups/:gid/instance/:iid", GroupController, :remove_instance)

    # TODO revoir routes
    post("/folders", FolderController, :create)
    put("/folders/:fid", FolderController, :update)
    delete("/folders/:fid", FolderController, :delete)

    # TODO: unused routes
    put("/admin/accounts/:aid", AccountController, :update)
    get("/logs", LogController, :index)

    post("/instance/:iid/snapshot/", InstanceSnapshotController, :save)
    delete("/instance/:iid/snapshot/:sid", InstanceSnapshotController, :delete)
    get("/instance/:iid/snapshot/", InstanceSnapshotController, :index)
    get("/instance/:iid/snapshot/:sid", InstanceSnapshotController, :load)
  end
end
