defmodule AgentExWeb.ProjectController do
  use AgentExWeb, :controller

  alias AgentEx.Projects

  def switch(conn, %{"id" => id}) do
    case Integer.parse(id) do
      {project_id, ""} ->
        user = conn.assigns.current_scope.user

        case Projects.get_user_project(user.id, project_id) do
          nil ->
            conn
            |> put_flash(:error, "Project not found")
            |> redirect(to: ~p"/chat")

          _project ->
            redirect_to = safe_redirect_path(conn)

            conn
            |> put_session("current_project_id", project_id)
            |> redirect(to: redirect_to)
        end

      _ ->
        conn
        |> put_flash(:error, "Invalid project ID")
        |> redirect(to: ~p"/chat")
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
