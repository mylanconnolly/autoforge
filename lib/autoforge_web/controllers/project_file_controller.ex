defmodule AutoforgeWeb.ProjectFileController do
  use AutoforgeWeb, :controller

  alias Autoforge.Projects.{ProjectFile, ProjectFiles}

  require Ash.Query

  def show(conn, %{"project_id" => project_id, "id" => file_id}) do
    user = conn.assigns[:current_user]

    if user do
      serve_file(conn, project_id, file_id, user)
    else
      conn
      |> put_status(401)
      |> text("Unauthorized")
    end
  end

  defp serve_file(conn, project_id, file_id, user) do
    project_file =
      ProjectFile
      |> Ash.Query.filter(id == ^file_id and project_id == ^project_id)
      |> Ash.read_one!(actor: user)

    case project_file do
      nil ->
        conn
        |> put_status(404)
        |> text("Not found")

      file ->
        case ProjectFiles.download(file) do
          {:ok, content} ->
            conn
            |> put_resp_content_type(file.content_type, "utf-8")
            |> put_resp_header(
              "content-disposition",
              ~s(inline; filename="#{file.filename}")
            )
            |> send_resp(200, content)

          {:error, _reason} ->
            conn
            |> put_status(502)
            |> text("Failed to download file")
        end
    end
  end
end
