defmodule Quire.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      QuireWeb.Telemetry,
      Quire.Repo,
      Quire.Vault,
      {Registry, keys: :duplicate, name: Quire.Editing.EditSessionRegistry},
      {Oban, Application.fetch_env!(:quire, Oban)},
      {DNSCluster, query: Application.get_env(:quire, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Quire.PubSub},
      {Quire.Editing.EditSessionSupervisor, []},
      # chromic_pdf looks up the instance by the module name (ChromicPDF), so
      # the supervisor must register under that name — not a custom one.
      # Options come from `config :quire, :chromic_pdf_opts` (dev.exs sets
      # `on_demand: true`): each print job spawns a temporary headless Chrome
      # which ConvertWorker.print_to_pdf_safely/2 terminates when the job
      # finishes (ChromicPDF's own teardown leaves the Chrome binary running
      # on macOS until the whole VM exits).
      {ChromicPDF, Application.get_env(:quire, :chromic_pdf_opts, [])},
      # Start a worker by calling: Quire.Worker.start_link(arg)
      # {Quire.Worker, arg},
      # Start to serve requests, typically the last entry
      QuireWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Quire.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Print the engine self-check table at boot. Disabled when running
        # `mix run --no-start` (doctor) or in test to avoid extra noise.
        unless System.get_env("QUIRE_SKIP_BOOT_CHECK") do
          Quire.Engine.print_boot_table()
        end

        # Initialise the tessdata cache directory and configure
        # :image_ocr, :tessdata_path so that Image.OCR discovers
        # both system-installed and downloaded packs (§T-141).
        unless System.get_env("QUIRE_SKIP_TESSDATA_INIT") do
          Quire.Ocr.Tessdata.init!()
        end

        # Reap orphaned on-demand Chrome instances from a crashed previous
        # run (worker killed mid-print etc.) plus their leftover profile
        # dirs. No-op unless dev's on-demand mode left tagged instances
        # behind; never touches the GUI Chrome. Best-effort: a sweep
        # failure must never fail the whole boot.
        try do
          Quire.Workers.ConvertWorker.sweep_stale_chromium()
        rescue
          e ->
            require Logger
            Logger.warning("boot chrome sweep failed: #{Exception.message(e)}")
        end

        {:ok, pid}

      error ->
        error
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    QuireWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
