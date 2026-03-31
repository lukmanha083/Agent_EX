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
        case Req.get(url, receive_timeout: 15_000, redirect: false) do
          {:ok, %{status: status, headers: headers}} when status in [301, 302, 303, 307, 308] ->
            handle_redirect(headers, max_length, 0)

          {:ok, %{status: 200, body: body}} when is_binary(body) ->
            {:ok, body |> strip_html() |> String.slice(0, max_length)}

          {:ok, %{status: status}} ->
            {:error, "HTTP #{status}"}

          {:error, reason} ->
            {:error, "Fetch failed: #{inspect(reason)}"}
        end
    end
  end

  @max_redirects 5

  defp handle_redirect(_headers, _max_length, depth) when depth >= @max_redirects do
    {:error, "too many redirects"}
  end

  defp handle_redirect(headers, max_length, depth) do
    location = get_header(headers, "location")

    if is_nil(location) do
      {:error, "redirect without location header"}
    else
      case AgentEx.NetworkPolicy.validate(location) do
        {:error, reason} ->
          {:error, "SSRF blocked on redirect: #{reason}"}

        :ok ->
          follow_redirect(location, max_length, depth)
      end
    end
  end

  defp follow_redirect(url, max_length, depth) do
    case Req.get(url, receive_timeout: 15_000, redirect: false) do
      {:ok, %{status: s, headers: h}} when s in [301, 302, 303, 307, 308] ->
        handle_redirect(h, max_length, depth + 1)

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body |> strip_html() |> String.slice(0, max_length)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, "Fetch failed: #{inspect(reason)}"}
    end
  end

  defp get_header(headers, name) do
    name_lower = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == name_lower, do: v
    end)
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
