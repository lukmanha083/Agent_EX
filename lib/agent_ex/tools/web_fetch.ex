defmodule AgentEx.Tools.WebFetch do
  @moduledoc """
  Local URL fetch tool — fetches a web page and extracts text content.

  Works with any model via standard tool calling.
  """

  @default_max_length 10_000

  @doc "Returns a Tool struct for URL fetching."
  def tool(opts \\ []) do
    max_length = Keyword.get(opts, :max_length, @default_max_length)

    AgentEx.Tools.single_param_tool(
      "web_fetch",
      "Fetch a URL and extract its text content.",
      "url",
      "URL to fetch",
      fn args -> execute(args, max_length) end
    )
  end

  defp execute(%{"url" => url}, max_length) do
    case AgentEx.NetworkPolicy.validate(url) do
      {:error, reason} ->
        {:error, "SSRF blocked: #{reason}"}

      :ok ->
        case Req.get(url, receive_timeout: 15_000, max_redirects: 5) do
          {:ok, %{status: 200, body: body}} when is_binary(body) ->
            {:ok, body |> strip_html() |> String.slice(0, max_length)}

          {:ok, %{status: status}} ->
            {:error, "HTTP #{status}"}

          {:error, reason} ->
            {:error, "Fetch failed: #{inspect(reason)}"}
        end
    end
  end

  @doc "Strip HTML tags and normalize whitespace from a string."
  def strip_html(html) do
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/s, "")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/s, "")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&[a-z]+;/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
