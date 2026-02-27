# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :ash_oban, pro?: false

config :autoforge, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  shutdown_grace_period: :timer.seconds(60),
  queues: [default: 10, ai: 5, sandbox: 3, github: 3, deployments: 3],
  repo: Autoforge.Repo,
  plugins: [
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", Autoforge.Projects.Workers.CleanupWorker}
     ]}
  ]

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :admin,
        :authentication,
        :token,
        :user_identity,
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:admin, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

config :autoforge,
  ecto_repos: [Autoforge.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    Autoforge.Accounts,
    Autoforge.Ai,
    Autoforge.Chat,
    Autoforge.Config,
    Autoforge.Deployments,
    Autoforge.Projects
  ],
  ash_authentication: [return_error_on_invalid_magic_link_token?: true]

# Configure the endpoint
config :autoforge, AutoforgeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AutoforgeWeb.ErrorHTML, json: AutoforgeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Autoforge.PubSub,
  live_view: [signing_salt: "v1hnqhbt"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :autoforge, Autoforge.Mailer, adapter: Swoosh.Adapters.Local

config :autoforge, Autoforge.Projects.Docker, socket_path: "/var/run/docker.sock"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  path: System.find_executable("esbuild"),
  version_check: false,
  autoforge: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  path: System.find_executable("tailwindcss"),
  version_check: false,
  autoforge: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
