defmodule Autoforge.Projects do
  use Ash.Domain, otp_app: :autoforge, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Autoforge.Projects.ProjectTemplate
    resource Autoforge.Projects.ProjectTemplateFile
    resource Autoforge.Projects.Project
    resource Autoforge.Projects.ProjectUserGroup
    resource Autoforge.Projects.ProjectTemplateUserGroup
    resource Autoforge.Projects.ProjectEnvVar
    resource Autoforge.Projects.ProjectFile
  end
end
