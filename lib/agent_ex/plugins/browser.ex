defmodule AgentEx.Plugins.Browser do
  @moduledoc """
  Browser automation plugin using Wallaby (headless Chrome).

  Gives agents the ability to navigate websites, fill forms, click buttons,
  and extract content — enabling tasks like ticket purchasing, form filling,
  and web scraping on behalf of users.

  Each agent gets an isolated browser session managed by SessionManager.
  Screenshots are captured after every action for UI streaming.
  """

  @behaviour AgentEx.ToolPlugin

  alias AgentEx.Browser.SessionManager
  alias AgentEx.Tool

  require Logger

  @impl true
  def manifest do
    %{
      name: "browser",
      description: "Headless browser automation (navigate, click, type, screenshot)",
      config_schema: []
    }
  end

  @impl true
  def init(_config) do
    tools = [
      navigate_tool(),
      click_tool(),
      type_tool(),
      screenshot_tool(),
      extract_tool(),
      select_tool(),
      wait_tool(),
      execute_js_tool()
    ]

    {:ok, tools}
  end

  # -- Tool definitions --

  defp navigate_tool do
    Tool.new(
      name: "navigate",
      description: "Navigate the browser to a URL. Returns page title and screenshot.",
      kind: :write,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "url" => %{"type" => "string", "description" => "The URL to navigate to"}
        },
        "required" => ["url"]
      },
      function: fn %{"url" => url} ->
        with_session(fn manager ->
          case SessionManager.navigate(manager, url) do
            {:ok, result} ->
              {:ok, "Navigated to #{result.url}\nTitle: #{result.title}"}

            {:error, reason} ->
              {:error, "Navigation failed: #{reason}"}
          end
        end)
      end
    )
  end

  defp click_tool do
    Tool.new(
      name: "click",
      description: "Click an element on the page by CSS selector.",
      kind: :write,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "selector" => %{
            "type" => "string",
            "description" =>
              "CSS selector of the element to click (e.g. '#submit-btn', '.buy-now')"
          }
        },
        "required" => ["selector"]
      },
      function: fn %{"selector" => selector} ->
        with_session(fn manager ->
          case SessionManager.click(manager, selector) do
            {:ok, result} -> {:ok, result.action}
            {:error, reason} -> {:error, "Click failed: #{reason}"}
          end
        end)
      end
    )
  end

  defp type_tool do
    Tool.new(
      name: "type",
      description: "Type text into an input field by CSS selector.",
      kind: :write,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "selector" => %{
            "type" => "string",
            "description" => "CSS selector of the input field"
          },
          "text" => %{
            "type" => "string",
            "description" => "Text to type into the field"
          }
        },
        "required" => ["selector", "text"]
      },
      function: fn %{"selector" => selector, "text" => text} ->
        with_session(fn manager ->
          case SessionManager.type(manager, selector, text) do
            {:ok, result} -> {:ok, result.action}
            {:error, reason} -> {:error, "Type failed: #{reason}"}
          end
        end)
      end
    )
  end

  defp screenshot_tool do
    Tool.new(
      name: "screenshot",
      description: "Take a screenshot of the current page. Returns base64-encoded PNG.",
      kind: :read,
      parameters: %{
        "type" => "object",
        "properties" => %{}
      },
      function: fn _args ->
        with_session(fn manager ->
          case SessionManager.screenshot(manager) do
            {:ok, base64} ->
              {:ok, "Screenshot captured (#{byte_size(base64 || "")} bytes base64)"}

            {:error, reason} ->
              {:error, "Screenshot failed: #{reason}"}
          end
        end)
      end
    )
  end

  defp extract_tool do
    Tool.new(
      name: "extract",
      description: "Extract text content from an element by CSS selector.",
      kind: :read,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "selector" => %{
            "type" => "string",
            "description" => "CSS selector of the element to extract text from"
          }
        },
        "required" => ["selector"]
      },
      function: fn %{"selector" => selector} ->
        with_session(fn manager ->
          case SessionManager.extract(manager, selector) do
            {:ok, text} -> {:ok, text}
            {:error, reason} -> {:error, "Extract failed: #{reason}"}
          end
        end)
      end
    )
  end

  defp select_tool do
    Tool.new(
      name: "select",
      description: "Select a dropdown option by CSS selector and value.",
      kind: :write,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "selector" => %{
            "type" => "string",
            "description" => "CSS selector of the <select> element"
          },
          "value" => %{
            "type" => "string",
            "description" => "The option text or value to select"
          }
        },
        "required" => ["selector", "value"]
      },
      function: fn %{"selector" => selector, "value" => value} ->
        with_session(fn manager ->
          case SessionManager.select(manager, selector, value) do
            {:ok, result} -> {:ok, result.action}
            {:error, reason} -> {:error, "Select failed: #{reason}"}
          end
        end)
      end
    )
  end

  defp wait_tool do
    Tool.new(
      name: "wait",
      description: "Wait for an element to appear on the page by CSS selector.",
      kind: :read,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "selector" => %{
            "type" => "string",
            "description" => "CSS selector to wait for"
          },
          "timeout" => %{
            "type" => "integer",
            "description" => "Max wait time in milliseconds (default: 10000)"
          }
        },
        "required" => ["selector"]
      },
      function: fn args ->
        selector = args["selector"]
        timeout = args["timeout"] || 10_000

        with_session(fn manager ->
          case SessionManager.wait_for(manager, selector, timeout) do
            {:ok, msg} -> {:ok, msg}
            {:error, reason} -> {:error, "Wait failed: #{reason}"}
          end
        end)
      end
    )
  end

  defp execute_js_tool do
    Tool.new(
      name: "execute_js",
      description: "Execute JavaScript in the browser and return the result.",
      kind: :write,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "script" => %{
            "type" => "string",
            "description" => "JavaScript code to execute"
          }
        },
        "required" => ["script"]
      },
      function: fn %{"script" => script} ->
        with_session(fn manager ->
          case SessionManager.execute_js(manager, script) do
            {:ok, result} -> {:ok, "JS result: #{inspect(result)}"}
            {:error, reason} -> {:error, "JS execution failed: #{reason}"}
          end
        end)
      end
    )
  end

  # -- Session management --

  # Get or create a browser session for the current process.
  # Sessions are stored in the process dictionary for simplicity.
  defp with_session(fun) do
    manager =
      case Process.get(:browser_session) do
        nil ->
          {:ok, pid} = SessionManager.start_link()
          Process.put(:browser_session, pid)
          pid

        pid ->
          if Process.alive?(pid), do: pid, else: start_new_session()
      end

    fun.(manager)
  rescue
    e ->
      Logger.warning("Browser: session error: #{Exception.message(e)}")
      {:error, "Browser session error: #{Exception.message(e)}"}
  end

  defp start_new_session do
    {:ok, pid} = SessionManager.start_link()
    Process.put(:browser_session, pid)
    pid
  end
end
