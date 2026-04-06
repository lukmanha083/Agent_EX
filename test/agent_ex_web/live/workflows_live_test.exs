defmodule AgentExWeb.WorkflowsLiveTest do
  use AgentExWeb.ConnCase

  import Phoenix.LiveViewTest
  import AgentEx.AccountsFixtures

  alias AgentEx.Workflow.{Edge, Node, Operators}
  alias AgentEx.Workflows

  setup :register_and_log_in_user

  defp create_workflow(project_id) do
    trigger_id = "node_trigger_#{System.unique_integer([:positive])}"
    output_id = "node_output_#{System.unique_integer([:positive])}"

    {:ok, workflow} =
      Workflows.create_workflow(%{
        project_id: project_id,
        name: "Test Workflow",
        nodes: [
          %Node{
            id: trigger_id,
            type: :trigger,
            label: "Trigger",
            position: %{"x" => 50, "y" => 100}
          },
          %Node{
            id: output_id,
            type: :output,
            label: "Output",
            position: %{"x" => 350, "y" => 100}
          }
        ],
        edges: []
      })

    %{workflow: workflow, trigger_id: trigger_id, output_id: output_id}
  end

  describe "edge validation — self-loop" do
    test "rejects connecting a node to itself", %{conn: conn, project: project} do
      %{workflow: workflow, trigger_id: trigger_id} = create_workflow(project.id)

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}")

      assert render_click(view, "add_edge", %{
               "source" => trigger_id,
               "target" => trigger_id
             }) =~ "Cannot connect a node to itself"
    end
  end

  describe "edge validation — cycle detection" do
    test "rejects edge that would create a cycle", %{conn: conn, project: project} do
      %{workflow: workflow, trigger_id: trigger_id, output_id: output_id} =
        create_workflow(project.id)

      # First add a valid edge: trigger -> output
      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}")

      render_click(view, "add_edge", %{
        "source" => trigger_id,
        "target" => output_id
      })

      # Now try to add a reverse edge: output -> trigger (creates cycle)
      assert render_click(view, "add_edge", %{
               "source" => output_id,
               "target" => trigger_id
             }) =~ "cycle"
    end
  end

  describe "code node — AST validation" do
    test "rejects String.to_atom in code node expression", %{conn: _conn, project: _project} do
      result =
        Operators.execute(
          %Node{
            id: "code_1",
            type: :code,
            label: "Code",
            config: %{"expression" => "String.to_atom(\"evil\")"},
            position: %{"x" => 0, "y" => 0}
          },
          %{},
          %{}
        )

      assert {:error, msg} = result
      assert msg =~ "not allowed"
    end

    test "rejects System.cmd in code node expression", %{conn: _conn, project: _project} do
      result =
        Operators.execute(
          %Node{
            id: "code_1",
            type: :code,
            label: "Code",
            config: %{"expression" => "System.cmd(\"whoami\", [])"},
            position: %{"x" => 0, "y" => 0}
          },
          %{},
          %{}
        )

      assert {:error, msg} = result
      assert msg =~ "not allowed"
    end

    test "allows safe Kernel operations in code node", %{conn: _conn, project: _project} do
      result =
        Operators.execute(
          %Node{
            id: "code_1",
            type: :code,
            label: "Code",
            config: %{"expression" => "1 + 2 + 3"},
            position: %{"x" => 0, "y" => 0}
          },
          %{},
          %{}
        )

      assert {:ok, 6} = result
    end
  end

  describe "workflow run — Task.shutdown" do
    test "running workflow completes without crash and shows result", %{
      conn: conn,
      project: project
    } do
      %{workflow: workflow, trigger_id: trigger_id, output_id: output_id} =
        create_workflow(project.id)

      # Connect trigger -> output so the workflow can run
      {:ok, workflow} =
        Workflows.update_workflow(workflow, %{
          edges: [
            %Edge{
              id: "edge_1",
              source_node_id: trigger_id,
              target_node_id: output_id,
              source_port: "output",
              target_port: "input"
            }
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}")

      # Trigger workflow run
      render_click(view, "run_workflow", %{})

      # Wait for the async task to deliver its result to the LiveView
      # The handle_info callback processes it and assigns run_result
      :timer.sleep(2000)

      html = render(view)
      # Should show either "Success" or "Error" — no crash
      assert html =~ "Success" or html =~ "Error"
    end
  end
end
