defmodule AgentExWeb.HttpToolComponents do
  @moduledoc """
  Components for the HTTP API tool builder — form fields, parameter table,
  and test panel.
  """

  use AgentExWeb, :html

  import AgentExWeb.CoreComponents, except: [button: 1]
  import SaladUI.Button

  @doc "Renders a grid of HTTP tool cards with a 'New HTTP Tool' button."
  attr(:tools, :list, required: true)

  def http_tool_grid(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between mb-2">
        <p class="text-sm text-gray-400">HTTP API tools — call REST endpoints as agent tools</p>
        <button
          type="button"
          phx-click="new_http_tool"
          class="inline-flex items-center gap-1.5 rounded-md bg-indigo-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-indigo-500 transition-colors"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
            <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
          </svg>
          New HTTP Tool
        </button>
      </div>

      <%= if @tools == [] do %>
        <div class="flex flex-col items-center justify-center py-8 text-center">
          <div class="flex h-10 w-10 items-center justify-center rounded-full bg-gray-800 mb-3">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4 text-gray-500">
              <path d="M2 3.5A1.5 1.5 0 0 1 3.5 2h2.879a1.5 1.5 0 0 1 1.06.44l1.122 1.12A1.5 1.5 0 0 0 9.62 4H12.5A1.5 1.5 0 0 1 14 5.5v1.401a2.986 2.986 0 0 0-4-1.283V5.5a.5.5 0 0 0-.5-.5H9.618a2.5 2.5 0 0 1-1.768-.732l-1.122-1.122A.5.5 0 0 0 6.38 3H3.5a.5.5 0 0 0-.5.5v9a.5.5 0 0 0 .5.5h4.257A2.991 2.991 0 0 0 10 14H3.5A1.5 1.5 0 0 1 2 12.5v-9Z" />
              <path d="M13.5 10a2.5 2.5 0 1 1-5 0 2.5 2.5 0 0 1 5 0Zm-2.5.75a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Z" />
            </svg>
          </div>
          <p class="text-sm text-gray-500">No HTTP tools defined yet</p>
        </div>
      <% else %>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <.http_tool_card :for={tool <- @tools} tool={tool} />
        </div>
      <% end %>
    </div>
    """
  end

  @doc "Renders a single HTTP tool card."
  attr(:tool, :map, required: true)

  def http_tool_card(assigns) do
    ~H"""
    <div class="group relative flex flex-col rounded-lg border border-gray-800 bg-gray-900 p-3 hover:border-gray-700 transition-colors">
      <div class="flex items-start justify-between mb-2">
        <div class="flex items-center gap-2">
          <.method_badge method={@tool.method} />
          <span class="text-sm font-medium text-white">{@tool.name}</span>
        </div>
        <div class="flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
          <button
            type="button"
            phx-click="edit_http_tool"
            phx-value-id={@tool.id}
            class="p-1 text-gray-400 hover:text-white transition-colors"
            aria-label="Edit"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
              <path d="M13.488 2.513a1.75 1.75 0 0 0-2.475 0L6.75 6.774a2.75 2.75 0 0 0-.596.892l-.848 2.047a.75.75 0 0 0 .98.98l2.047-.848a2.75 2.75 0 0 0 .892-.596l4.261-4.262a1.75 1.75 0 0 0 0-2.474Z" />
              <path d="M4.75 3.5c-.69 0-1.25.56-1.25 1.25v6.5c0 .69.56 1.25 1.25 1.25h6.5c.69 0 1.25-.56 1.25-1.25V9A.75.75 0 0 1 14 9v2.25A2.75 2.75 0 0 1 11.25 14h-6.5A2.75 2.75 0 0 1 2 11.25v-6.5A2.75 2.75 0 0 1 4.75 2H7a.75.75 0 0 1 0 1.5H4.75Z" />
            </svg>
          </button>
          <button
            type="button"
            phx-click="delete_http_tool"
            phx-value-id={@tool.id}
            data-confirm="Delete this HTTP tool?"
            class="p-1 text-gray-400 hover:text-red-400 transition-colors"
            aria-label="Delete"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
              <path fill-rule="evenodd" d="M5 3.25V4H2.75a.75.75 0 0 0 0 1.5h.3l.815 8.15A1.5 1.5 0 0 0 5.357 15h5.285a1.5 1.5 0 0 0 1.493-1.35l.815-8.15h.3a.75.75 0 0 0 0-1.5H11v-.75A2.25 2.25 0 0 0 8.75 1h-1.5A2.25 2.25 0 0 0 5 3.25Zm2.25-.75a.75.75 0 0 0-.75.75V4h3v-.75a.75.75 0 0 0-.75-.75h-1.5ZM6.05 6a.75.75 0 0 1 .787.713l.275 5.5a.75.75 0 0 1-1.498.075l-.275-5.5A.75.75 0 0 1 6.05 6Zm3.9 0a.75.75 0 0 1 .712.787l-.275 5.5a.75.75 0 0 1-1.498-.075l.275-5.5a.75.75 0 0 1 .786-.712Z" clip-rule="evenodd" />
            </svg>
          </button>
        </div>
      </div>
      <p :if={@tool.description} class="text-xs text-gray-400 line-clamp-2 mb-2">{@tool.description}</p>
      <p class="text-[10px] text-gray-500 font-mono truncate">{@tool.url_template}</p>
    </div>
    """
  end

  @doc "HTTP tool editor dialog."
  attr(:show, :boolean, default: false)
  attr(:form, :map, required: true)
  attr(:editing, :boolean, default: false)
  attr(:test_result, :string, default: nil)
  attr(:test_loading, :boolean, default: false)

  def http_tool_editor_dialog(assigns) do
    ~H"""
    <div :if={@show} class="fixed inset-0 z-50 flex items-center justify-center" role="dialog" aria-modal="true">
      <div class="fixed inset-0 bg-black/60" phx-click="close_http_editor"></div>
      <div data-testid="http-tool-dialog" class="relative z-10 w-full max-w-lg mx-4 rounded-lg border border-gray-800 bg-gray-900 p-6 shadow-xl max-h-[90vh] overflow-y-auto">
        <div class="mb-4">
          <h2 class="text-lg font-semibold text-white">
            {if @editing, do: "Edit HTTP Tool", else: "New HTTP Tool"}
          </h2>
          <p class="text-sm text-gray-400 mt-1">Define an HTTP API endpoint as an agent tool.</p>
        </div>

        <.form for={@form} phx-submit="save_http_tool" phx-change="validate_http_tool" class="space-y-4">
          <input type="hidden" name="tool_id" value={@form[:id]} />

          <.input type="text" name="name" value={@form[:name]} label="Tool Name" placeholder="e.g. stock_api.get_quote" required />
          <.input type="text" name="description" value={@form[:description]} label="Description" placeholder="What does this tool do?" />

          <div class="grid grid-cols-2 gap-3">
            <.input
              type="select"
              name="method"
              value={@form[:method] || "GET"}
              label="Method"
              options={[{"GET", "GET"}, {"POST", "POST"}, {"PUT", "PUT"}, {"PATCH", "PATCH"}, {"DELETE", "DELETE"}]}
            />
            <.input
              type="select"
              name="kind"
              value={to_string(@form[:kind] || "read")}
              label="Kind"
              options={[{"Read (sensing)", "read"}, {"Write (acting)", "write"}]}
            />
          </div>

          <.input
            type="text"
            name="url_template"
            value={@form[:url_template]}
            label="URL Template"
            placeholder="https://api.example.com/quote/{{ticker}}"
            required
          />

          <div>
            <label class="block text-sm font-medium text-gray-300 mb-1">Headers (JSON)</label>
            <textarea
              name="headers_json"
              rows="2"
              class="w-full rounded-md border border-gray-700 bg-gray-800 px-3 py-2 text-sm text-gray-200 placeholder-gray-500 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 font-mono"
              placeholder={~s|{"Authorization": "Bearer {{api_key}}"}|}
            >{format_headers(@form[:headers])}</textarea>
          </div>

          <%!-- Parameters --%>
          <div>
            <div class="flex items-center justify-between mb-2">
              <label class="text-sm font-medium text-gray-300">Parameters</label>
              <button
                type="button"
                phx-click="add_http_param"
                class="text-xs text-indigo-400 hover:text-indigo-300 transition-colors"
              >
                + Add Parameter
              </button>
            </div>
            <div :if={@form[:parameters] != [] and @form[:parameters] != nil} class="space-y-2">
              <div :for={{param, idx} <- Enum.with_index(@form[:parameters] || [])} class="flex gap-2 items-start">
                <input type="text" name={"params[#{idx}][name]"} value={param[:name] || param["name"]} placeholder="name" class="flex-1 rounded-md border border-gray-700 bg-gray-800 px-2 py-1.5 text-xs text-gray-200 placeholder-gray-500 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500" />
                <select name={"params[#{idx}][type]"} class="w-20 rounded-md border border-gray-700 bg-gray-800 px-2 py-1.5 text-xs text-gray-200 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500">
                  <option value="string" selected={param_type(param) == "string"}>string</option>
                  <option value="number" selected={param_type(param) == "number"}>number</option>
                  <option value="integer" selected={param_type(param) == "integer"}>integer</option>
                  <option value="boolean" selected={param_type(param) == "boolean"}>boolean</option>
                </select>
                <input type="text" name={"params[#{idx}][description]"} value={param[:description] || param["description"]} placeholder="description" class="flex-[2] rounded-md border border-gray-700 bg-gray-800 px-2 py-1.5 text-xs text-gray-200 placeholder-gray-500 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500" />
                <label class="flex items-center gap-1 text-xs text-gray-400 shrink-0">
                  <input type="checkbox" name={"params[#{idx}][required]"} value="true" checked={param[:required] == true or param["required"] == true or param["required"] == "true"} class="rounded border-gray-600 bg-gray-800 text-indigo-600 focus:ring-indigo-500" />
                  req
                </label>
                <button
                  type="button"
                  phx-click="remove_http_param"
                  phx-value-index={idx}
                  class="p-1 text-gray-500 hover:text-red-400 transition-colors shrink-0"
                >
                  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
                    <path d="M5.28 4.22a.75.75 0 0 0-1.06 1.06L6.94 8l-2.72 2.72a.75.75 0 1 0 1.06 1.06L8 9.06l2.72 2.72a.75.75 0 1 0 1.06-1.06L9.06 8l2.72-2.72a.75.75 0 0 0-1.06-1.06L8 6.94 5.28 4.22Z" />
                  </svg>
                </button>
              </div>
            </div>
            <p :if={@form[:parameters] == [] or @form[:parameters] == nil} class="text-xs text-gray-500 italic">No parameters defined</p>
          </div>

          <div class="grid grid-cols-2 gap-3">
            <.input
              type="select"
              name="response_type"
              value={@form[:response_type] || "json_body"}
              label="Response"
              options={[{"JSON body", "json_body"}, {"Raw text", "raw_text"}]}
            />
            <.input type="text" name="response_path" value={@form[:response_path]} label="JSON Path" placeholder="e.g. data.results" />
          </div>

          <%!-- Test result --%>
          <div :if={@test_result} class="rounded-md border border-gray-700 bg-gray-800 p-3">
            <label class="block text-xs font-medium text-gray-400 mb-1">Test Result</label>
            <pre class="text-xs text-gray-300 whitespace-pre-wrap max-h-32 overflow-y-auto">{@test_result}</pre>
          </div>

          <div class="flex justify-between pt-2">
            <.button
              type="button"
              variant="outline"
              phx-click="test_http_tool"
              disabled={@test_loading}
              class="border-gray-700 text-gray-300 hover:bg-gray-800"
            >
              {if @test_loading, do: "Testing...", else: "Test"}
            </.button>
            <div class="flex gap-2">
              <.button type="button" variant="outline" phx-click="close_http_editor" class="border-gray-700 text-gray-300 hover:bg-gray-800">
                Cancel
              </.button>
              <.button type="submit" class="bg-indigo-600 hover:bg-indigo-500 text-white">
                Save
              </.button>
            </div>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp method_badge(assigns) do
    color =
      case assigns.method do
        "GET" -> "bg-emerald-600/20 text-emerald-400"
        "POST" -> "bg-blue-600/20 text-blue-400"
        "PUT" -> "bg-amber-600/20 text-amber-400"
        "PATCH" -> "bg-purple-600/20 text-purple-400"
        "DELETE" -> "bg-red-600/20 text-red-400"
        _ -> "bg-gray-600/20 text-gray-400"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-bold #{@color}"}>
      {@method}
    </span>
    """
  end

  defp format_headers(nil), do: ""
  defp format_headers(headers) when headers == %{}, do: ""
  defp format_headers(headers) when is_map(headers), do: Jason.encode!(headers, pretty: true)
  defp format_headers(_), do: ""

  defp param_type(param) do
    param[:type] || param["type"] || "string"
  end
end
