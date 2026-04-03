defmodule AgentEx.Workflow.Operators do
  @moduledoc """
  Built-in operator implementations for workflow nodes.

  Three categories:
  - **Data operators** — pure JSON transforms (no side effects, no LLM)
  - **Flow control** — branching and merging
  - **I/O operators** — HTTP requests, tool calls, agent delegation, output

  Each operator receives `(node_config, input_data, context)` and returns
  `{:ok, output}`, `{:branch, port, output}`, or `{:error, reason}`.
  """

  alias AgentEx.Workflow.Expression

  @doc "Execute a node by type."
  def execute(%{type: type, config: config}, input, context) do
    execute_type(type, config, input, context)
  end

  # ============================================================
  # TRIGGER — entry point, passes through trigger data
  # ============================================================

  defp execute_type(:trigger, _config, input, _ctx), do: {:ok, input}

  # ============================================================
  # DATA OPERATORS
  # ============================================================

  @doc false
  defp execute_type(:json_extract, config, input, _ctx) do
    paths = config["paths"] || []

    result =
      Enum.reduce(paths, %{}, fn path, acc ->
        keys = String.split(path, ".")
        field_name = List.last(keys)
        value = get_nested(input, keys)
        Map.put(acc, field_name, value)
      end)

    {:ok, result}
  end

  defp execute_type(:json_transform, config, input, _ctx) do
    mappings = config["mappings"] || []

    result =
      Enum.reduce(mappings, input, fn mapping, acc ->
        {old_key, new_key} = parse_mapping(mapping)
        value = Map.get(acc, old_key)
        acc |> Map.delete(old_key) |> Map.put(new_key, value)
      end)

    {:ok, result}
  end

  defp execute_type(:json_filter, config, input, _ctx) do
    path = config["path"] || "items"
    condition = config["condition"]

    keys = String.split(path, ".")
    items = get_nested(input, keys) || []

    filtered =
      if condition do
        Enum.filter(items, &evaluate_filter_condition(&1, condition))
      else
        items
      end

    {:ok, put_nested(input, keys, filtered)}
  end

  defp execute_type(:json_merge, _config, input, _ctx) when is_list(input) do
    result = Enum.reduce(input, %{}, &deep_merge/2)
    {:ok, result}
  end

  defp execute_type(:json_merge, _config, input, _ctx), do: {:ok, input}

  defp execute_type(:set, config, input, _ctx) do
    values = config["values"] || %{}
    {:ok, Map.merge(input || %{}, values)}
  end

  defp execute_type(:code, config, input, _ctx) do
    expression = config["expression"] || ""
    evaluate_safe_expression(expression, input)
  end

  # ============================================================
  # FLOW CONTROL OPERATORS
  # ============================================================

  defp execute_type(:if_branch, config, input, ctx) do
    condition = %{
      "path" => resolve_condition_path(config, ctx),
      "operator" => config["operator"] || "==",
      "expected" => config["expected"]
    }

    # Also support simple path + equals shorthand
    condition =
      if config["equals"] do
        Map.put(condition, "equals", config["equals"])
      else
        condition
      end

    result = Expression.evaluate_condition(condition, Map.get(ctx, :results, %{}))

    if result do
      {:branch, "true", input}
    else
      {:branch, "false", input}
    end
  end

  defp execute_type(:switch, config, input, ctx) do
    path = resolve_condition_path(config, ctx)
    value = Expression.extract_value(path, Map.get(ctx, :results, %{}))
    cases = config["cases"] || []

    port =
      Enum.find(cases, fn c -> to_string(c) == to_string(value) end)
      |> case do
        nil -> "default"
        matched -> "case_#{matched}"
      end

    {:branch, port, input}
  end

  defp execute_type(:split, config, input, _ctx) do
    path = config["path"] || "items"
    keys = String.split(path, ".")
    items = get_nested(input, keys) || []

    {:ok, %{"__split_items" => items}}
  end

  defp execute_type(:merge, _config, input, _ctx) when is_list(input) do
    {:ok, %{"merged" => input}}
  end

  defp execute_type(:merge, _config, input, _ctx), do: {:ok, input}

  # ============================================================
  # I/O OPERATORS
  # ============================================================

  defp execute_type(:http_request, config, input, ctx) do
    results = Map.get(ctx, :results, %{})
    merged = Map.merge(results, %{"input" => input})

    method = (config["method"] || "GET") |> String.downcase() |> String.to_existing_atom()
    url = Expression.interpolate(config["url"] || "", merged)
    headers = resolve_headers(config["headers"] || %{}, merged)

    case AgentEx.NetworkPolicy.validate(url) do
      {:error, reason} -> {:error, "SSRF blocked: #{reason}"}
      :ok -> do_http_request(method, url, headers, config, input, merged)
    end
  end

  defp execute_type(:tool, config, input, ctx) do
    tool_name = config["tool_name"]
    tools = Map.get(ctx, :tools, [])

    case Enum.find(tools, &(&1.name == tool_name)) do
      nil ->
        {:error, "tool not found: #{tool_name}"}

      tool ->
        param_mapping = config["param_mapping"] || %{}
        results = Map.get(ctx, :results, %{})
        args = resolve_tool_args(param_mapping, input, results)

        case tool.function.(args) do
          {:ok, result} ->
            decoded = try_decode_json(result)
            {:ok, decoded}

          {:error, reason} ->
            {:error, "tool #{tool_name} failed: #{inspect(reason)}"}
        end
    end
  end

  defp execute_type(:agent, config, input, ctx) do
    agent_id = config["agent_id"]
    task_template = config["task_template"] || "{{input}}"
    results = Map.get(ctx, :results, %{})
    merged = Map.merge(results, %{"input" => input})

    task = Expression.interpolate(task_template, merged)

    case Map.get(ctx, :agent_runner) do
      nil ->
        {:error, "no agent_runner provided in context"}

      runner when is_function(runner, 2) ->
        case runner.(agent_id, task) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, "agent #{agent_id} failed: #{inspect(reason)}"}
        end
    end
  end

  defp execute_type(:output, config, input, _ctx) do
    format = config["format"] || "json"

    result =
      case format do
        "text" when is_binary(input) -> input
        "text" -> Jason.encode!(input)
        "json" -> input
        "table" -> %{"table" => input}
        _ -> input
      end

    {:ok, result}
  end

  defp execute_type(unknown, _config, _input, _ctx) do
    {:error, "unknown node type: #{inspect(unknown)}"}
  end

  # ============================================================
  # HELPERS
  # ============================================================

  defp do_http_request(method, url, headers, config, input, merged) do
    body = if config["body"], do: Expression.resolve(config["body"], merged), else: input

    req_opts = [method: method, url: url, headers: headers, receive_timeout: 15_000, redirect: false]
    req_opts = if method in [:post, :put, :patch], do: Keyword.put(req_opts, :json, body), else: req_opts

    case Req.request(req_opts) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 -> {:ok, resp_body}
      {:ok, %{status: status, body: resp_body}} -> {:error, "HTTP #{status}: #{inspect(resp_body)}"}
      {:error, exception} -> {:error, "HTTP error: #{inspect(exception)}"}
    end
  end

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

  defp put_nested(map, [key], value) when is_map(map), do: Map.put(map, key, value)

  defp put_nested(map, [key | rest], value) when is_map(map) do
    nested = Map.get(map, key, %{})
    Map.put(map, key, put_nested(nested, rest, value))
  end

  defp put_nested(_, _, value), do: value

  defp parse_mapping([old, new]), do: {old, new}
  defp parse_mapping({old, new}), do: {old, new}
  defp parse_mapping(%{"from" => old, "to" => new}), do: {old, new}
  defp parse_mapping(_), do: {"", ""}

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(right, left, fn _k, v1, v2 ->
      if is_map(v1) and is_map(v2), do: deep_merge(v1, v2), else: v1
    end)
  end

  defp deep_merge(left, _right), do: left

  defp evaluate_filter_condition(item, condition) when is_binary(condition) do
    # Simple conditions: "> 10", "== active", "!= null"
    case Regex.run(~r/^(>=?|<=?|==|!=)\s*(.+)$/, String.trim(condition)) do
      [_, op, expected_str] ->
        expected = parse_value(String.trim(expected_str))
        compare_filter(item, op, expected)

      _ ->
        true
    end
  end

  defp evaluate_filter_condition(_item, _condition), do: true

  defp compare_filter(a, ">", b) when is_number(a) and is_number(b), do: a > b
  defp compare_filter(a, "<", b) when is_number(a) and is_number(b), do: a < b
  defp compare_filter(a, ">=", b) when is_number(a) and is_number(b), do: a >= b
  defp compare_filter(a, "<=", b) when is_number(a) and is_number(b), do: a <= b
  defp compare_filter(a, "==", b), do: to_string(a) == to_string(b)
  defp compare_filter(a, "!=", b), do: to_string(a) != to_string(b)
  defp compare_filter(_, _, _), do: false

  defp parse_value("null"), do: nil
  defp parse_value("true"), do: true
  defp parse_value("false"), do: false

  defp parse_value(str) do
    case Float.parse(str) do
      {num, ""} -> num
      _ -> str
    end
  end

  defp resolve_condition_path(config, ctx) do
    path = config["path"] || ""

    if String.starts_with?(path, "{{") do
      path
    else
      maybe_wrap_path(path, Map.get(ctx, :results, %{}))
    end
  end

  defp maybe_wrap_path(path, results) do
    case String.split(path, ".", parts: 2) do
      [node_id, _rest] when map_size(results) > 0 ->
        if Map.has_key?(results, node_id), do: "{{#{path}}}", else: path

      _ ->
        path
    end
  end

  defp resolve_headers(headers, results) when is_map(headers) do
    Map.new(headers, fn {k, v} -> {k, Expression.interpolate(v, results)} end)
  end

  defp resolve_tool_args(mapping, input, results) when is_map(mapping) do
    merged = Map.merge(results, %{"input" => input})

    Map.new(mapping, fn {param_name, source} ->
      value = Expression.extract_value(source, merged)
      {param_name, value}
    end)
  end

  defp resolve_tool_args(_, input, _results) when is_map(input), do: input
  defp resolve_tool_args(_, _input, _results), do: %{}

  defp try_decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp try_decode_json(value), do: value

  # Safe expression evaluator — parses the expression into AST and validates
  # that only whitelisted modules/functions are called before evaluating.
  # Blocks access to System, File, Port, :os, Code, Process, etc.
  defp evaluate_safe_expression(expression, input) do
    case Code.string_to_quoted(expression) do
      {:ok, ast} ->
        case validate_ast(ast) do
          :ok ->
            {result, _} = Code.eval_quoted(ast, [input: input])
            {:ok, result}

          {:error, reason} ->
            {:error, "blocked: #{reason}"}
        end

      {:error, {_line, msg, token}} ->
        {:error, "syntax error: #{msg} #{token}"}
    end
  rescue
    e -> {:error, "code evaluation error: #{Exception.message(e)}"}
  end

  @allowed_modules [Map, Enum, String, Kernel, List, Tuple, Access]
  @blocked_atoms ~w(
    System File Port Code IO Process Node
    :os :erlang :persistent_term Application
  )a

  defp validate_ast({:., _, [{:__aliases__, _, _mod_parts} = mod, _func]}) do
    case Macro.expand(mod, __ENV__) do
      m when m in @allowed_modules -> :ok
      m -> {:error, "module #{inspect(m)} is not allowed"}
    end
  rescue
    _ -> {:error, "unknown module reference"}
  end

  defp validate_ast({:., _, [mod, _func]}) when is_atom(mod) do
    if mod in @blocked_atoms do
      {:error, "module #{inspect(mod)} is not allowed"}
    else
      :ok
    end
  end

  defp validate_ast({:__aliases__, _, parts}) do
    mod_name = Module.concat(parts)

    if mod_name in @allowed_modules do
      :ok
    else
      {:error, "module #{inspect(mod_name)} is not allowed"}
    end
  rescue
    _ -> {:error, "invalid module reference"}
  end

  defp validate_ast({call, _, args}) when is_atom(call) and is_list(args) do
    if call in @blocked_atoms do
      {:error, "#{call} is not allowed"}
    else
      validate_ast_list(args)
    end
  end

  defp validate_ast({left, right}), do: validate_ast_list([left, right])
  defp validate_ast({a, b, c}), do: validate_ast_list([a, b, c])
  defp validate_ast(list) when is_list(list), do: validate_ast_list(list)
  defp validate_ast(_literal), do: :ok

  defp validate_ast_list(items) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case validate_ast(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
