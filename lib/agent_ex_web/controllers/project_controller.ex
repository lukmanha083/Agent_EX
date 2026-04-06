defmodule AgentExWeb.ProjectController do
  use AgentExWeb, :controller

  alias AgentEx.Projects

  def switch(conn, %{"id" => id}) do
    case Integer.parse(id) do
      {project_id, ""} ->
        user = conn.assigns.current_scope.user

        user.id
        |> Projects.get_user_project(project_id)
        |> switch_to_project(conn)

      _ ->
        conn
        |> put_flash(:error, "Invalid project ID")
        |> redirect(to: ~p"/chat")
    end
  end

  defp switch_to_project(nil, conn) do
    conn |> put_flash(:error, "Project not found") |> redirect(to: ~p"/projects")
  end

  defp switch_to_project(project, conn) do
    if Projects.project_available?(project) do
      conn
      |> put_session("current_project_id", project.id)
      |> redirect(to: safe_redirect_path(conn))
    else
      conn
      |> put_flash(:error, "Project unavailable — directory not found on this machine")
      |> redirect(to: ~p"/projects")
    end
  end

  defp safe_redirect_path(conn) do
    case get_req_header(conn, "referer") do
      [referer | _] ->
        case URI.parse(referer) do
          %URI{path: "/" <> _ = path} -> path
          _ -> "/chat"
        end

      _ ->
        "/chat"
    end
  end
end
