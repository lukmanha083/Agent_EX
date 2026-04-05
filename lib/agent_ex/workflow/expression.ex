defmodule AgentEx.Workflow.Expression do
  @moduledoc """
  Template interpolation and condition evaluation for workflow nodes.

  Resolves `{{node_id.path.to.field}}` references against workflow execution state.
  Evaluates simple conditions for if/switch nodes — no arbitrary code execution.

  ## Interpolation

      iex> results = %{"trigger" => %{"body" => %{"ticker" => "AAPL"}}}
      iex> Expression.interpolate("https://api.example.com/quote/{{trigger.body.ticker}}", results)
      "https://api.example.com/quote/AAPL"

  ## Conditions

  Supports: `==`, `!=`, `>`, `<`, `>=`, `<=`, `contains`, `matches`, `empty`, `not_empty`
  """

  @doc "Resolve {{node_id.path}} references in a template string."
  def interpolate(template, _results) when not is_binary(template), do: template

  def interpolate(template, results) do
    Regex.replace(~r/\{\{([\w]+(?:\.[\w.]+)?)\}\}/, template, fn _match, ref ->
      case String.split(ref, ".") do
        [single] ->
          value = Map.get(results, single)
          format_value(value)

        [node_id | keys] ->
          value = get_nested(results, [node_id | keys])
          format_value(value)
      end
    end)
  end

  @doc "Resolve {{node_id.path}} references in any value (string, map, list)."
  def resolve(value, results) when is_binary(value), do: interpolate(value, results)

  def resolve(value, results) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, resolve(v, results)} end)
  end

  def resolve(value, results) when is_list(value) do
    Enum.map(value, &resolve(&1, results))
  end

  def resolve(value, _results), do: value

  @doc "Extract a single value from results given a `{{node_id.path}}` reference."
  def extract_value(ref, results) when is_binary(ref) do
    case Regex.run(~r/^\{\{([\w]+(?:\.[\w.]+)?)\}\}$/, ref) do
      [_, inner] ->
        case String.split(inner, ".") do
          [single] -> Map.get(results, single)
          [node_id | keys] -> get_nested(results, [node_id | keys])
        end

      _ ->
        # Not a reference, try interpolation in case it's a mixed string
        interpolate(ref, results)
    end
  end

  def extract_value(value, _results), do: value

  @doc """
  Evaluate a condition against workflow results.

  Condition format: `{path_or_ref, operator, expected}`

  ## Operators
  - `"=="`, `"!="` — equality
  - `">"`, `"<"`, `">="`, `"<="` — numeric comparison
  - `"contains"` — substring/member check
  - `"matches"` — regex match
  - `"empty"` — nil, "", or []  (expected is ignored)
  - `"not_empty"` — negation of empty
  """
  def evaluate_condition(%{"path" => path, "operator" => op} = condition, results) do
    value = extract_value(path, results)
    expected = Map.get(condition, "expected")
    expected = if is_binary(expected), do: extract_value(expected, results), else: expected
    compare(value, op, expected)
  end

  def evaluate_condition(%{"path" => path, "equals" => expected}, results) do
    value = extract_value(path, results)
    to_comparable(value) == to_comparable(expected)
  end

  def evaluate_condition(_condition, _results), do: false

  # --- Comparison operators ---

  defp compare(value, "==", expected), do: to_comparable(value) == to_comparable(expected)
  defp compare(value, "!=", expected), do: to_comparable(value) != to_comparable(expected)

  defp compare(value, op, expected) when op in ~w(> < >= <=) do
    with {:ok, a} <- safe_to_number(value),
         {:ok, b} <- safe_to_number(expected) do
      case op do
        ">" -> a > b
        "<" -> a < b
        ">=" -> a >= b
        "<=" -> a <= b
      end
    else
      :error -> false
    end
  end

  defp compare(value, "contains", expected) when is_binary(value) and is_binary(expected) do
    String.contains?(value, expected)
  end

  defp compare(value, "contains", expected) when is_list(value), do: expected in value
  defp compare(_value, "contains", _expected), do: false

  defp compare(value, "matches", pattern) when is_binary(value) and is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, value)
      _ -> false
    end
  end

  defp compare(_value, "matches", _pattern), do: false

  defp compare(value, "empty", _expected), do: empty?(value)
  defp compare(value, "not_empty", _expected), do: not empty?(value)

  defp compare(_value, _op, _expected), do: false

  # --- Helpers ---

  defp get_nested(nil, _keys), do: nil
  defp get_nested(value, []), do: value

  defp get_nested(map, [key | rest]) when is_map(map) do
    value =
      case Map.fetch(map, key) do
        {:ok, v} -> v
        :error -> Map.get(map, safe_to_atom(key))
      end

    get_nested(value, rest)
  end

  defp get_nested(_, _), do: nil

  defp safe_to_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  defp safe_to_atom(_), do: nil

  defp format_value(nil), do: ""
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_number(value), do: to_string(value)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(value), do: Jason.encode!(value)

  defp to_comparable(value) when is_binary(value) do
    case Float.parse(value) do
      {num, ""} -> num
      _ -> value
    end
  end

  defp to_comparable(value), do: value

  defp safe_to_number(value) when is_number(value), do: {:ok, value}

  defp safe_to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {num, ""} -> {:ok, num}
      _ -> :error
    end
  end

  defp safe_to_number(_), do: :error

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(%{} = map) when map_size(map) == 0, do: true
  defp empty?(_), do: false
end
