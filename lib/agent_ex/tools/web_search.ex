defmodule AgentEx.Tools.WebSearch do
  @moduledoc """
  Local web search tool using SerpAPI.

  Works with any model via standard tool calling — no provider built-in required.
  """

  @doc "Returns a Tool struct for web search."
  def tool(opts \\ []) do
    AgentEx.Tools.single_param_tool(
      "web_search",
      "Search the web and return result snippets.",
      "query",
      "Search query",
      fn args -> execute(args, opts) end
    )
  end

  defp execute(%{"query" => query}, opts) do
    api_key = Keyword.get(opts, :api_key) || resolve_api_key()

    case Req.get("https://serpapi.com/search",
           params: [q: query, api_key: api_key, num: 5],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, extract_results(body)}

      {:ok, %{status: status}} ->
        {:error, "Search API returned status #{status}"}

      {:error, reason} ->
        {:error, "Search request failed: #{inspect(reason)}"}
    end
  end

  defp extract_results(%{"organic_results" => results}) when is_list(results) do
    results
    |> Enum.take(5)
    |> Enum.map_join("\n\n", fn r ->
      "#{r["title"] || ""}\n#{r["snippet"] || ""}\n#{r["link"] || ""}"
    end)
  end

  defp extract_results(_body), do: "No results found."

  defp resolve_api_key do
    Application.get_env(:agent_ex, :serpapi_api_key) ||
      System.get_env("SERPAPI_API_KEY") || ""
  end
end
