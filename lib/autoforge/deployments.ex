defmodule Autoforge.Deployments do
  use Ash.Domain, otp_app: :autoforge, extensions: [AshAdmin.Domain, AshPaperTrail.Domain]

  admin do
    show? true
  end

  paper_trail do
    include_versions? true
  end

  resources do
    resource Autoforge.Deployments.VmTemplate
    resource Autoforge.Deployments.VmInstance
    resource Autoforge.Deployments.Deployment
    resource Autoforge.Deployments.DeploymentEnvVar
  end
end
