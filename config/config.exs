# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :quire, :scopes,
  user: [
    default: true,
    module: Quire.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :owner_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: Quire.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :quire,
  ecto_repos: [Quire.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  storage_adapter: Quire.Storage.Web,
  storage_backend: Quire.Storage.Web.Filesystem,
  render_adapter: Quire.Render.Pdfium

config :quire, Oban,
  repo: Quire.Repo,
  queues: [
    render: 1,
    transform: 1,
    convert: 1,
    ocr: 1,
    secure: 2,
    esign: 2,
    translate: 2,
    batch: 1,
    maintenance: 1
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 604_800},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Reindexer, schedule: "@weekly"}
  ]

# Configure the endpoint
config :quire, QuireWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: QuireWeb.ErrorHTML, json: QuireWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Quire.PubSub,
  live_view: [signing_salt: "kAfh3PPB"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :quire, Quire.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  quire: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  quire: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
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
