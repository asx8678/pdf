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
