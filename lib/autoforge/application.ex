defmodule Autoforge.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AutoforgeWeb.Telemetry,
      Autoforge.Vault,
      Autoforge.Repo,
      {DNSCluster, query: Application.get_env(:autoforge, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:autoforge, :ash_domains),
         Application.fetch_env!(:autoforge, Oban)
       )},
      {Phoenix.PubSub, name: Autoforge.PubSub},
      # Start a worker by calling: Autoforge.Worker.start_link(arg)
      # {Autoforge.Worker, arg},
      {Task.Supervisor, name: Autoforge.TaskSupervisor},
      {Registry, keys: :unique, name: Autoforge.DevServerRegistry},
      {DynamicSupervisor, name: Autoforge.Projects.DevServerSupervisor, strategy: :one_for_one},
      # Start to serve requests, typically the last entry
      AutoforgeWeb.Endpoint,
      Autoforge.Projects.DevServerCleanup,
      {AshAuthentication.Supervisor, [otp_app: :autoforge]}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Autoforge.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AutoforgeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
