defmodule AgentEx.Plugins.AskUser do
  @moduledoc """
  Built-in plugin for asking the user questions mid-execution.

  Provides a single tool that pauses the agent loop by blocking on a
  user-provided callback function. The callback handles the actual IO
  (stdin, HTTP endpoint, websocket — consumer's choice).

  ## Config

  - `"handler"` — `(String.t() -> {:ok, String.t()} | {:error, term()})`
    Function that receives the question and returns the user's answer.
    Not part of `config_schema` (functions aren't serializable).

  ## Example

      PluginRegistry.attach(reg, AgentEx.Plugins.AskUser, %{
        "handler" => fn question ->
          {:ok, IO.gets("\#{question}\\n> ") |> String.trim()}
        end
      })
  """

  @behaviour AgentEx.ToolPlugin

  alias AgentEx.Tool

  @impl true
  def manifest do
    %{
      name: "ask_user",
      version: "1.0.0",
      description: "Ask the user questions during agent execution",
      config_schema: []
    }
  end

  @impl true
  def init(config) do
    handler = Map.get(config, "handler") || (&default_handler/1)
    {:ok, [question_tool(handler)]}
  end

  defp question_tool(handler) do
    Tool.new(
      name: "question",
      description:
        "Ask the user a question and wait for their response. " <>
          "Use when you need clarification, confirmation, or additional " <>
          "information before proceeding.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "question" => %{
            "type" => "string",
            "description" => "The question to ask the user"
          },
          "context" => %{
            "type" => "string",
            "description" => "Brief context for why you're asking (shown to user)"
          }
        },
        "required" => ["question"]
      },
      kind: :write,
      function: fn args ->
        question = Map.fetch!(args, "question")
        context = Map.get(args, "context")
        prompt = if context, do: "[#{context}]\n#{question}", else: question

        case handler.(prompt) do
          {:ok, answer} when is_binary(answer) -> {:ok, answer}
          {:error, reason} -> {:error, "User interaction failed: #{inspect(reason)}"}
          other -> {:error, "Handler returned unexpected value: #{inspect(other)}"}
        end
      end
    )
  end

  defp default_handler(_question) do
    {:error, "No handler configured. Attach plugin with a \"handler\" function in config."}
  end
end
