defmodule AutoforgeWeb.Router do
  use AutoforgeWeb, :router

  import Oban.Web.Router
  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AutoforgeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
  end

  scope "/", AutoforgeWeb do
    pipe_through :browser

    ash_authentication_live_session :authenticated_routes do
      # in each liveview, add one of the following at the top of the module:
      #
      # If an authenticated user must be present:
      # on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}
      #
      # If an authenticated user *may* be present:
      # on_mount {AutoforgeWeb.LiveUserAuth, :live_user_optional}
      #
      # If an authenticated user must *not* be present:
      # on_mount {AutoforgeWeb.LiveUserAuth, :live_no_user}
      live "/dashboard", DashboardLive
      live "/profile", ProfileLive
      live "/bots", BotsLive
      live "/bots/new", BotFormLive, :new
      live "/bots/:id/edit", BotFormLive, :edit
      live "/bots/:id", BotShowLive
      live "/users", UsersLive
      live "/users/new", UserFormLive, :new
      live "/users/:id/edit", UserFormLive, :edit
      live "/users/:id", UserShowLive
      live "/user-groups", UserGroupsLive
      live "/user-groups/new", UserGroupFormLive, :new
      live "/user-groups/:id/edit", UserGroupFormLive, :edit
      live "/user-groups/:id", UserGroupShowLive
      live "/project-templates", ProjectTemplatesLive
      live "/project-templates/new", ProjectTemplateFormLive, :new
      live "/project-templates/:id/edit", ProjectTemplateFormLive, :edit
      live "/project-templates/:id/files", ProjectTemplateFilesLive
      live "/settings", SettingsLive
      live "/models", ModelsLive
      live "/projects", ProjectsLive
      live "/projects/new", ProjectFormLive
      live "/projects/:id", ProjectLive
      live "/projects/:id/settings", ProjectSettingsLive
      live "/conversations", ConversationsLive
      live "/conversations/new", ConversationFormLive
      live "/conversations/:id", ConversationLive
    end
  end

  scope "/", AutoforgeWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/projects/:project_id/files/:id", ProjectFileController, :show
    auth_routes AuthController, Autoforge.Accounts.User, path: "/auth"
    sign_out_route AuthController

    # Remove these if you'd like to use your own authentication views
    sign_in_route register_path: "/register",
                  reset_path: "/reset",
                  auth_routes_prefix: "/auth",
                  on_mount: [{AutoforgeWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    AutoforgeWeb.AuthOverrides,
                    Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
                  ]

    # Remove this if you do not want to use the reset password feature
    reset_route auth_routes_prefix: "/auth",
                overrides: [
                  AutoforgeWeb.AuthOverrides,
                  Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
                ]

    # Remove this if you do not use the confirmation strategy
    confirm_route Autoforge.Accounts.User, :confirm_new_user,
      auth_routes_prefix: "/auth",
      overrides: [AutoforgeWeb.AuthOverrides, Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI]

    # Remove this if you do not use the magic link strategy.
    magic_sign_in_route(Autoforge.Accounts.User, :magic_link,
      auth_routes_prefix: "/auth",
      overrides: [AutoforgeWeb.AuthOverrides, Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI]
    )
  end

  # Other scopes may use custom stacks.
  # scope "/api", AutoforgeWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:autoforge, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AutoforgeWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    scope "/" do
      pipe_through :browser

      oban_dashboard("/oban")
    end
  end

  if Application.compile_env(:autoforge, :dev_routes) do
    import AshAdmin.Router

    scope "/admin" do
      pipe_through :browser

      ash_admin "/"
    end
  end
end
