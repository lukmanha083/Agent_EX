defmodule AgentExWeb.InterventionBuilderLive do
  use AgentExWeb, :live_view

  import AgentExWeb.InterventionComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       pipeline: [],
       available: available_handlers()
     )}
  end

  @impl true
  def handle_event("add_handler", %{"id" => id}, socket) do
    already_added = Enum.any?(socket.assigns.pipeline, &(&1.id == id))

    if already_added do
      {:noreply, socket}
    else
      handler = %{id: id}
      pipeline = socket.assigns.pipeline ++ [handler]
      {:noreply, assign(socket, pipeline: pipeline)}
    end
  end

  def handle_event("remove_handler", %{"id" => id}, socket) do
    pipeline = Enum.reject(socket.assigns.pipeline, &(&1.id == id))
    {:noreply, assign(socket, pipeline: pipeline)}
  end

  def handle_event("reorder_pipeline", %{"ids" => ids}, socket) do
    pipeline = Enum.map(ids, fn id -> %{id: id} end)
    {:noreply, assign(socket, pipeline: pipeline)}
  end
end
