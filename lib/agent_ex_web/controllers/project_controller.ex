defmodule AgentExWeb.ProjectController do
  use AgentExWeb, :controller

  alias AgentEx.Projects

  def switch(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user

    with {project_id, ""} <- Integer.parse(id),
         %{} = _project <- Projects.get_user_project(user.id, project_id) do
      conn
      |> put_session("current_project_id", project_id)
      |> redirect(to: safe_redirect_path(conn))
    else
      _ ->
        conn
        |> put_flash(:error, "Project not found")
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
