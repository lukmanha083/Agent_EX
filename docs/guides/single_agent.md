# Single-Agent Guide — Building Computer-Use Agents

This guide walks you through building single-agent systems with AgentEx, progressing
from a minimal shell executor to a fully sandboxed, memory-integrated computer-use
agent. Each section is self-contained with real, runnable code.

**Prerequisites:**
- An LLM API key (`OPENAI_API_KEY` or `ANTHROPIC_API_KEY` environment variable)
- `iex -S mix` for running examples interactively

**Table of Contents**

1. [Minimal Agent — Shell Command Executor](#1-minimal-agent--shell-command-executor)
2. [Multi-Tool Agent — File Operations Assistant](#2-multi-tool-agent--file-operations-assistant)
3. [Tool Definition Ergonomics](#3-tool-definition-ergonomics)
4. [Read/Write Permissions — Safe Computer Use](#4-readwrite-permissions--safe-computer-use)
5. [Custom Intervention — Sandboxing the Agent](#5-custom-intervention--sandboxing-the-agent)
6. [Error Handling & Resilience](#6-error-handling--resilience)
7. [Memory Integration](#7-memory-integration)
8. [Tuning & Options Reference](#8-tuning--options-reference)

---

## 1. Minimal Agent — Shell Command Executor

**Scenario:** Build an agent that can run bash commands to answer questions about
your system.

### Define a real tool

The `bash_exec` tool uses `System.cmd/3` to execute shell commands and return
their output. This is a real, functional tool — the LLM can run `uname -a`,
`df -h`, `whoami`, and anything else your shell supports.

```elixir
alias AgentEx.{Message, ModelClient, Tool, ToolAgent, ToolCallerLoop}

# A real tool that executes shell commands
bash_tool = Tool.new(
  name: "bash_exec",
  description: "Execute a bash command and return stdout. Use for system queries.",
  kind: :write,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "command" => %{
        "type" => "string",
        "description" => "The bash command to execute"
      }
    },
    "required" => ["command"]
  },
  function: fn %{"command" => command} ->
    case System.cmd("bash", ["-c", command], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:ok, "exit code #{code}:\n#{output}"}
    end
  end
)
```

### Wire up the agent

```elixir
# Start the ToolAgent GenServer with our tool
{:ok, agent} = ToolAgent.start_link(tools: [bash_tool])

# Create the LLM client (defaults to OpenAI)
client = ModelClient.new(model: "gpt-4o")
# Or: client = ModelClient.anthropic("claude-sonnet-4-20250514")

# Build input messages
messages = [
  Message.system("You are a system administration assistant. Use bash_exec to answer questions about the user's machine."),
  Message.user("What OS am I running and how much disk space is available?")
]

# Run the Sense-Think-Act loop
{:ok, generated} = ToolCallerLoop.run(agent, client, messages, [bash_tool])

IO.puts(List.last(generated).content)
```

### Under the hood — one loop iteration

When you call `ToolCallerLoop.run/5`, here's what happens step by step:

```text
messages = [system, user]     ← you provide these
     │
     ▼
┌─ Iteration 1 ─────────────────────────────────────────────┐
│                                                            │
│  THINK ─▶ LLM receives [system, user] + tool schemas      │
│     │     LLM returns: assistant message with tool_calls   │
│     │     tool_calls = [%FunctionCall{name: "bash_exec",   │
│     │                    arguments: "{\"command\":          │
│     │                    \"uname -a && df -h\"}"}]         │
│     │                                                      │
│     ▼     generated = [assistant_with_tool_calls]          │
│                                                            │
│  SENSE ─▶ Sensing.sense(agent, tool_calls)                 │
│     │     1. intervene — no handlers, auto-approve         │
│     │     2. dispatch — Task.async_stream executes tool    │
│     │        System.cmd("bash", ["-c", "uname -a && …"])   │
│     │     3. process — wrap stdout in FunctionResult       │
│     │     4. feed_back — package as tool role Message      │
│     │                                                      │
│     ▼     generated = [assistant_with_tool_calls,          │
│                         tool_results_message]              │
│                                                            │
│  THINK ─▶ LLM receives [system, user, assistant, tool]    │
│     │     LLM sees the command output                      │
│     │     LLM returns: assistant message with text         │
│     │     (no tool_calls → loop exits)                     │
│     │                                                      │
│     ▼     generated = [assistant_with_tool_calls,          │
│                         tool_results_message,              │
│                         assistant_text_response]           │
│                                                            │
│  ACT ──▶ Return {:ok, generated}                           │
└────────────────────────────────────────────────────────────┘
```

The `generated` list accumulates three messages:
1. `%Message{role: :assistant, tool_calls: [...]}` — LLM's tool request
2. `%Message{role: :tool, content: [%FunctionResult{...}]}` — tool output
3. `%Message{role: :assistant, content: "You're running Linux..."}` — final answer

---

## 2. Multi-Tool Agent — File Operations Assistant

**Scenario:** Build an assistant that can search, read, and analyze files on your
machine using multiple tools.

### Define the tools

```elixir
alias AgentEx.{Message, ModelClient, Tool, ToolAgent, ToolCallerLoop}

bash_tool = Tool.new(
  name: "bash_exec",
  description: "Execute a bash command. Use for find, ls, wc, and other system commands.",
  kind: :write,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "command" => %{"type" => "string", "description" => "Bash command to execute"}
    },
    "required" => ["command"]
  },
  function: fn %{"command" => command} ->
    case System.cmd("bash", ["-c", command], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:ok, "exit code #{code}:\n#{output}"}
    end
  end
)

read_file_tool = Tool.new(
  name: "read_file",
  description: "Read the full contents of a file at the given path.",
  kind: :read,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "Absolute file path"}
    },
    "required" => ["path"]
  },
  function: fn %{"path" => path} ->
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
    end
  end
)

list_dir_tool = Tool.new(
  name: "list_directory",
  description: "List files and directories at the given path.",
  kind: :read,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "Directory path"}
    },
    "required" => ["path"]
  },
  function: fn %{"path" => path} ->
    case File.ls(path) do
      {:ok, entries} -> {:ok, Enum.join(entries, "\n")}
      {:error, reason} -> {:error, "Cannot list #{path}: #{reason}"}
    end
  end
)

grep_tool = Tool.new(
  name: "grep_search",
  description: "Search for a pattern in files. Returns matching lines with file paths and line numbers.",
  kind: :read,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "pattern" => %{"type" => "string", "description" => "Search pattern (regex)"},
      "path" => %{"type" => "string", "description" => "Directory or file to search"}
    },
    "required" => ["pattern", "path"]
  },
  function: fn %{"pattern" => pattern, "path" => path} ->
    case System.cmd("grep", ["-rn", pattern, path], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, 1} -> {:ok, "No matches found"}
      {output, _} -> {:error, output}
    end
  end
)

tools = [bash_tool, read_file_tool, list_dir_tool, grep_tool]
```

### Run the multi-tool agent

```elixir
{:ok, agent} = ToolAgent.start_link(tools: tools)
client = ModelClient.new(model: "gpt-4o")

messages = [
  Message.system("""
  You are a code analysis assistant. You can search, read, and analyze files.
  Use grep_search to find files, read_file to examine them, and bash_exec for
  other operations. Always explain your findings.
  """),
  Message.user("Find all Elixir files that define a GenServer and tell me what each one does")
]

{:ok, generated} = ToolCallerLoop.run(agent, client, messages, tools)
IO.puts(List.last(generated).content)
```

### Under the hood — multi-iteration flow

The LLM typically needs multiple iterations to search, then read, then analyze:

```text
Iteration 1: THINK → "I need to find GenServer files"
             SENSE → grep_search("use GenServer", "lib/")
                     → returns list of matching files

Iteration 2: THINK → "Let me read those files to understand them"
             SENSE → read_file("lib/agent_ex/tool_agent.ex")
                     read_file("lib/agent_ex/workbench.ex")
                     read_file("lib/agent_ex/mcp/client.ex")
                     → 3 tools dispatched in parallel via Task.async_stream

Iteration 3: THINK → "I now have enough info to answer"
             ACT   → returns summary of each GenServer's purpose
```

When the LLM returns multiple `FunctionCall` structs in a single response,
`Sensing.dispatch/3` runs them all concurrently with `Task.async_stream`. Each
tool executes in its own BEAM process — if one file read fails, the others still
complete.

---

## 3. Tool Definition Ergonomics

**Scenario:** Define the same tools using `ToolBuilder` and the `deftool` macro
instead of writing JSON Schema by hand.

### Before: verbose JSON Schema

```elixir
Tool.new(
  name: "read_file",
  description: "Read file contents",
  kind: :read,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "Absolute file path"}
    },
    "required" => ["path"]
  },
  function: fn %{"path" => path} ->
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
    end
  end
)
```

### After: ToolBuilder.build/1

`ToolBuilder.build/1` generates the JSON Schema from a declarative param spec:

```elixir
alias AgentEx.ToolBuilder

ToolBuilder.build(
  name: "read_file",
  description: "Read file contents",
  kind: :read,
  params: [
    {:path, :string, "Absolute file path"}
  ],
  function: fn %{"path" => path} ->
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
    end
  end
)
```

### After: deftool macro

For tools grouped in a module, `deftool` generates a `<name>_tool/0` function
that returns the `%Tool{}` struct. You define the tool function separately:

```elixir
defmodule ComputerTools do
  import AgentEx.ToolBuilder

  deftool :bash_exec, "Execute a bash command and return stdout", kind: :write do
    param :command, :string, "The bash command to execute"
  end

  def bash_exec(%{"command" => command}) do
    case System.cmd("bash", ["-c", command], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:ok, "exit code #{code}:\n#{output}"}
    end
  end

  deftool :read_file, "Read the full contents of a file" do
    param :path, :string, "Absolute file path"
  end

  def read_file(%{"path" => path}) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
    end
  end

  deftool :write_file, "Write content to a file", kind: :write do
    param :path, :string, "Absolute file path"
    param :content, :string, "Content to write"
  end

  def write_file(%{"path" => path, "content" => content}) do
    case File.write(path, content) do
      :ok -> {:ok, "Written #{byte_size(content)} bytes to #{path}"}
      {:error, reason} -> {:error, "Cannot write #{path}: #{reason}"}
    end
  end

  deftool :copy_file, "Copy a file to a new location", kind: :write do
    param :source, :string, "Source file path"
    param :destination, :string, "Destination file path"
  end

  def copy_file(%{"source" => src, "destination" => dest}) do
    case File.cp(src, dest) do
      :ok -> {:ok, "Copied #{src} → #{dest}"}
      {:error, reason} -> {:error, "Cannot copy: #{reason}"}
    end
  end
end
```

Usage:

```elixir
# Each deftool generates a <name>_tool/0 function
tools = [
  ComputerTools.bash_exec_tool(),
  ComputerTools.read_file_tool(),
  ComputerTools.write_file_tool(),
  ComputerTools.copy_file_tool()
]

{:ok, agent} = ToolAgent.start_link(tools: tools)
```

### Type mapping reference

| Param type | JSON Schema output |
|---|---|
| `:string` | `{"type": "string"}` |
| `:integer` | `{"type": "integer"}` |
| `:number` | `{"type": "number"}` |
| `:boolean` | `{"type": "boolean"}` |
| `{:enum, ["a", "b"]}` | `{"type": "string", "enum": ["a", "b"]}` |
| `{:array, :string}` | `{"type": "array", "items": {"type": "string"}}` |
| `{:object, fields}` | Nested `{"type": "object", "properties": {...}}` |

Optional parameters are excluded from `required`:

```elixir
deftool :grep_search, "Search files for a pattern" do
  param :pattern, :string, "Search pattern (regex)"
  param :path, :string, "Directory or file to search"
  param :max_results, :integer, "Maximum matches to return", optional: true
end
```

See [ToolBuilder](../modules.md#agentextoolbuilder) in the module reference.

---

## 4. Read/Write Permissions — Safe Computer Use

**Scenario:** Give the agent read access to your filesystem but control which
write operations are allowed.

### The problem

Giving an LLM unrestricted shell access is dangerous. It could overwrite config
files, delete data, or execute destructive commands. AgentEx solves this with
tool **kinds** and **intervention handlers** — like Linux file permissions for
AI tool use.

### Define tools with kinds

```elixir
alias AgentEx.{Message, ModelClient, Tool, ToolAgent, ToolCallerLoop}
alias AgentEx.Intervention.{PermissionHandler, WriteGateHandler}

# Read tools — the agent can use these freely
read_file = Tool.new(
  name: "read_file",
  description: "Read file contents",
  kind: :read,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "File path"}
    },
    "required" => ["path"]
  },
  function: fn %{"path" => path} ->
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
    end
  end
)

grep_search = Tool.new(
  name: "grep_search",
  description: "Search for a pattern in files",
  kind: :read,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "pattern" => %{"type" => "string", "description" => "Search pattern"},
      "path" => %{"type" => "string", "description" => "Search path"}
    },
    "required" => ["pattern", "path"]
  },
  function: fn %{"pattern" => pattern, "path" => path} ->
    case System.cmd("grep", ["-rn", pattern, path], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, 1} -> {:ok, "No matches found"}
      {output, _} -> {:error, output}
    end
  end
)

# Write tools — gated by intervention handlers
write_file = Tool.new(
  name: "write_file",
  description: "Write content to a file (creates or overwrites)",
  kind: :write,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "File path"},
      "content" => %{"type" => "string", "description" => "Content to write"}
    },
    "required" => ["path", "content"]
  },
  function: fn %{"path" => path, "content" => content} ->
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      {:ok, "Written #{byte_size(content)} bytes to #{path}"}
    else
      {:error, reason} -> {:error, "Cannot write #{path}: #{reason}"}
    end
  end
)

copy_file = Tool.new(
  name: "copy_file",
  description: "Copy a file to a new location",
  kind: :write,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "source" => %{"type" => "string", "description" => "Source path"},
      "destination" => %{"type" => "string", "description" => "Destination path"}
    },
    "required" => ["source", "destination"]
  },
  function: fn %{"source" => src, "destination" => dest} ->
    case File.cp(src, dest) do
      :ok -> {:ok, "Copied #{src} → #{dest}"}
      {:error, reason} -> {:error, "Cannot copy: #{reason}"}
    end
  end
)

bash_exec = Tool.new(
  name: "bash_exec",
  description: "Execute a shell command (can modify system state)",
  kind: :write,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "command" => %{"type" => "string", "description" => "Command to execute"}
    },
    "required" => ["command"]
  },
  function: fn %{"command" => command} ->
    case System.cmd("bash", ["-c", command], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:ok, "exit code #{code}:\n#{output}"}
    end
  end
)

tools = [read_file, grep_search, write_file, copy_file, bash_exec]
```

### Built-in handlers

**`PermissionHandler`** — blocks all `:write` tools (like `chmod 444`):

```elixir
# Total lockdown — read-only mode
{:ok, agent} = ToolAgent.start_link(tools: tools)
client = ModelClient.new(model: "gpt-4o")

ToolCallerLoop.run(agent, client, messages, tools,
  intervention: [PermissionHandler]
)
# read_file, grep_search → auto-approved
# write_file, copy_file, bash_exec → REJECTED
```

**`WriteGateHandler`** — allows specific `:write` tools (like `chmod +w`):

```elixir
# Allow write_file and copy_file, but block bash_exec
gate = WriteGateHandler.new(allowed_writes: ["write_file", "copy_file"])

ToolCallerLoop.run(agent, client, messages, tools,
  intervention: [gate]
)
# read_file, grep_search → auto-approved (kind: :read)
# write_file, copy_file  → approved (in allowlist)
# bash_exec              → REJECTED (kind: :write, not in allowlist)
```

### Combining handlers

Handlers run as a pipeline — first non-`:approve` decision wins:

```elixir
alias AgentEx.Intervention.LogHandler

ToolCallerLoop.run(agent, client, messages, tools,
  intervention: [LogHandler, gate]
)
# 1. LogHandler — logs every call, always returns :approve
# 2. gate — approves :read tools and allowlisted :write tools
```

### Complete example

```elixir
{:ok, agent} = ToolAgent.start_link(tools: tools)
client = ModelClient.new(model: "gpt-4o")

messages = [
  Message.system("""
  You are a file management assistant. You can read, search, write, and copy files.
  When asked to back up a file, read it first, then copy it.
  """),
  Message.user("Read the config file at /tmp/app.conf and create a backup copy at /tmp/app.conf.bak")
]

gate = WriteGateHandler.new(allowed_writes: ["copy_file"])

{:ok, generated} = ToolCallerLoop.run(agent, client, messages, tools,
  intervention: [LogHandler, gate]
)

IO.puts(List.last(generated).content)
# The agent reads /tmp/app.conf (auto-approved), then copies it (allowed).
# If it tries bash_exec or write_file, those get rejected.
```

### Permission decision matrix

| Tool | Kind | `PermissionHandler` | `WriteGateHandler.new(allowed_writes: ["copy_file"])` |
|---|---|---|---|
| `read_file` | `:read` | approve | approve |
| `grep_search` | `:read` | approve | approve |
| `write_file` | `:write` | **reject** | **reject** |
| `copy_file` | `:write` | **reject** | approve |
| `bash_exec` | `:write` | **reject** | **reject** |

---

## 5. Custom Intervention — Sandboxing the Agent

**Scenario:** Restrict the agent to only operate within a specific directory,
block dangerous commands, and auto-rewrite relative paths.

### The Intervention behaviour

An intervention handler receives a `FunctionCall`, the `Tool` definition (or
`nil` if unknown), and a context map. It returns one of four decisions:

| Decision | Effect |
|---|---|
| `:approve` | Tool call proceeds to execution |
| `:reject` | Tool call returns an error `FunctionResult` to the LLM |
| `:drop` | Tool call is silently removed (LLM never sees it) |
| `{:modify, %FunctionCall{}}` | Tool call is rewritten before execution |

Handlers can be **modules** (implementing `@behaviour AgentEx.Intervention`)
or **closures** (3-arity functions).

### Path sandbox — closure handler

Reject any file operation targeting paths outside `/tmp/sandbox/`:

```elixir
sandbox_root = "/tmp/sandbox"

path_sandbox = fn call, _tool, _context ->
  case Jason.decode(call.arguments) do
    {:ok, %{} = args} ->
      paths = [args["path"], args["source"], args["destination"]]
              |> Enum.reject(&is_nil/1)

      expanded_root = Path.expand(sandbox_root)
      sandbox_prefix = expanded_root <> "/"

      if Enum.all?(paths, fn p ->
        expanded = Path.expand(p)
        expanded == expanded_root or String.starts_with?(expanded, sandbox_prefix)
      end) do
        :approve
      else
        :reject
      end

    _ ->
      :approve
  end
end
```

### Command blocklist — module handler

Reject `bash_exec` calls containing dangerous commands:

```elixir
defmodule CommandBlocklist do
  @behaviour AgentEx.Intervention

  @blocked ~w(rm sudo chmod chown mkfs dd shutdown reboot)

  @impl true
  def on_call(%{name: "bash_exec"} = call, _tool, _context) do
    case Jason.decode(call.arguments) do
      {:ok, %{"command" => command}} ->
        tokens =
          command
          |> String.split(~r/[^a-zA-Z0-9_.\/-]+/)
          |> Enum.map(fn t -> t |> Path.basename() |> String.downcase() end)

        if Enum.any?(@blocked, fn cmd -> cmd in tokens end) do
          :reject
        else
          :approve
        end

      _ ->
        :approve
    end
  end

  def on_call(_call, _tool, _context), do: :approve
end
```

### Argument rewriter — modify handler

Auto-prepend the sandbox path to relative file paths:

```elixir
sandbox_root = "/tmp/sandbox"

path_rewriter = fn call, _tool, _context ->
  case Jason.decode(call.arguments) do
    {:ok, %{} = args} ->
      rewrite = fn
        nil -> nil
        "/" <> _ = abs -> abs
        relative -> Path.join(sandbox_root, relative)
      end

      new_args =
        args
        |> Map.update("path", nil, rewrite)
        |> Map.update("source", nil, rewrite)
        |> Map.update("destination", nil, rewrite)
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      if new_args == args do
        :approve
      else
        {:modify, %{call | arguments: Jason.encode!(new_args)}}
      end

    _ ->
      :approve
  end
end
```

When the LLM calls `read_file` with `{"path": "config.txt"}`, this handler
rewrites it to `{"path": "/tmp/sandbox/config.txt"}` before execution.

### Composing the pipeline

```elixir
alias AgentEx.Intervention.{LogHandler, WriteGateHandler}

gate = WriteGateHandler.new(allowed_writes: ["write_file", "copy_file"])

{:ok, generated} = ToolCallerLoop.run(agent, client, messages, tools,
  intervention: [
    LogHandler,            # 1. Log everything (always approves)
    path_rewriter,         # 2. Rewrite relative paths to sandbox
    CommandBlocklist,       # 3. Block dangerous bash commands
    path_sandbox,          # 4. Reject paths outside sandbox
    gate                   # 5. Gate write tools by allowlist
  ]
)
```

Pipeline evaluation order matters. Each handler sees the (potentially modified)
call from the previous handler. First non-`:approve` decision short-circuits —
remaining handlers are skipped for that call.

### Using context

The context map provides iteration state to handlers:

```elixir
rate_limiter = fn _call, _tool, context ->
  if context.iteration > 20 do
    :reject
  else
    :approve
  end
end
```

The context map contains:
- `iteration` — current loop iteration number (0-indexed)
- `generated_messages` — all messages generated so far in this loop run

---

## 6. Error Handling & Resilience

**Scenario:** What happens when commands fail, files don't exist, or tools
timeout?

### Error classification

| Error source | What happens | LLM sees |
|---|---|---|
| Tool returns `{:error, reason}` | Wrapped as error result | `%FunctionResult{content: reason, is_error: true}` |
| Tool raises an exception | Caught by `Tool.execute/2` rescue | `%FunctionResult{content: "Error: ...", is_error: true}` |
| Tool times out | `Task.async_stream` kills the task | `%FunctionResult{content: "Error: ...", is_error: true}` |
| Unknown tool name | `ToolAgent` returns error | `%FunctionResult{content: "Error: unknown tool '...'"}`  |
| Invalid JSON arguments | `Jason.decode` fails | `%FunctionResult{content: "Error: invalid JSON arguments"}` |
| Intervention rejects call | Immediate error result | `%FunctionResult{content: "Error: ...", is_error: true}` |

### Errors become LLM feedback

The key principle: errors don't crash the loop. They become `FunctionResult`
messages with `is_error: true`, and the LLM sees the error text as a tool
observation. A well-prompted LLM will adjust and try a different approach.

```elixir
# Tool that can fail
read_file = Tool.new(
  name: "read_file",
  description: "Read file contents",
  kind: :read,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "File path"}
    },
    "required" => ["path"]
  },
  function: fn %{"path" => path} ->
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "File not found: #{path}"}
      {:error, :eacces} -> {:error, "Permission denied: #{path}"}
      {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
    end
  end
)
```

When the LLM calls `read_file` on a nonexistent path:

```text
Iteration 1: THINK → calls read_file("/tmp/missing.txt")
             SENSE → FunctionResult{content: "File not found: /tmp/missing.txt",
                                    is_error: true}
Iteration 2: THINK → "That file doesn't exist, let me try listing the directory"
             SENSE → calls list_directory("/tmp/")
             ...
```

### BEAM process isolation

Each tool call dispatched by `Sensing.dispatch/3` runs in its own process via
`Task.async_stream`. If one tool crashes, the others continue executing:

```text
dispatch([read_file("/a"), read_file("/b"), read_file("/c")])
     │           │           │
     ▼           ▼           ▼
  Task 1      Task 2      Task 3     ← separate BEAM processes
  (crash)     (success)   (success)
     │           │           │
     ▼           ▼           ▼
  error       result      result      ← all results collected
```

### Timeout protection

Set `tool_timeout` to limit how long any single tool call can run:

```elixir
{:ok, generated} = ToolCallerLoop.run(agent, client, messages, tools,
  tool_timeout: 5_000  # 5 second timeout per tool call (default: 30_000)
)
```

This passes through to `Sensing.sense/3` as the `:timeout` option, which
controls the `Task.async_stream` timeout. When a tool exceeds the timeout,
the task is killed and the LLM receives an error result.

### Iteration limit

Prevent infinite loops with `max_iterations`:

```elixir
{:ok, generated} = ToolCallerLoop.run(agent, client, messages, tools,
  max_iterations: 5  # Stop after 5 sensing rounds (default: 10)
)
```

When the limit is reached, the loop returns the messages accumulated so far.
The last message may be a tool result rather than an assistant text response.

---

## 7. Memory Integration

**Scenario:** Build an agent that remembers file locations and previous analysis
across sessions.

### Enable memory in the loop

Pass a `memory` option to `ToolCallerLoop.run/5` to enable automatic memory
integration:

```elixir
alias AgentEx.{Memory, Message, ModelClient, ToolAgent, ToolCallerLoop}

# Start a memory session for this agent
{:ok, _} = Memory.start_session("file-agent", "session-1")

tools = [read_file_tool, grep_search_tool, list_dir_tool]
{:ok, agent} = ToolAgent.start_link(tools: tools)
client = ModelClient.new(model: "gpt-4o")

# Session 1: discover test files
messages = [
  Message.system("You are a code assistant. Remember important findings for later."),
  Message.user("Find all test files in this project and summarize what they test")
]

{:ok, _generated} = ToolCallerLoop.run(agent, client, messages, tools,
  memory: %{agent_id: "file-agent", session_id: "session-1"}
)
```

With the `memory` option, `ToolCallerLoop` automatically:
1. Calls `Memory.inject_memory_context/3` to prepend memory context as system
   messages before the first LLM call
2. Stores user messages in working memory (Tier 1)
3. Stores the assistant's final response in working memory

### Persistent memory — remember across sessions

Use Tier 2 (key-value) to explicitly store facts that survive restarts:

```elixir
# Store a discovery
Memory.remember("file-agent", "test_locations", "test/agent_ex/tool_test.exs, test/agent_ex/sensing_test.exs", "fact")

# Later, in a new session
{:ok, _} = Memory.start_session("file-agent", "session-2")

{:ok, entry} = Memory.recall("file-agent", "test_locations")
# entry.value => "test/agent_ex/tool_test.exs, test/agent_ex/sensing_test.exs"

# Session 2: use recalled knowledge
messages = [
  Message.system("You are a code assistant."),
  Message.user("Run the tests you found earlier")
]

{:ok, _generated} = ToolCallerLoop.run(agent, client, messages, tools,
  memory: %{agent_id: "file-agent", session_id: "session-2"}
)
# Memory context is injected — the LLM sees previously stored facts
```

### 3-tier overview

| Tier | Storage | Scope | Use case |
|---|---|---|---|
| 1 — Working Memory | GenServer (per-session) | Session | Current conversation history |
| 2 — Persistent Memory | ETS + DETS | Agent | Key-value facts, preferences |
| 3 — Semantic Memory | HelixDB vectors | Agent | Similarity search over past knowledge |

Plus the **Knowledge Graph** for entity/relationship extraction and hybrid
graph+vector retrieval.

See [Memory System](../memory.md) for the full guide covering all tiers,
knowledge graph, context builder, and configuration.

### Clean up

```elixir
Memory.stop_session("file-agent", "session-1")
Memory.stop_session("file-agent", "session-2")
```

---

## 8. Tuning & Options Reference

### ToolCallerLoop.run/5

```elixir
ToolCallerLoop.run(tool_agent, model_client, input_messages, tools, opts \\ [])
```

| Option | Type | Default | Description |
|---|---|---|---|
| `max_iterations` | `pos_integer()` | `10` | Maximum sensing rounds before forced exit |
| `caller_source` | `String.t()` | `"assistant"` | Source label on generated assistant messages |
| `tool_timeout` | `pos_integer()` | `30_000` | Per-tool execution timeout in milliseconds |
| `intervention` | `[handler()]` | `[]` | Intervention handler pipeline |
| `memory` | `memory_opts() \| nil` | `nil` | Memory integration config |

`memory_opts` is `%{agent_id: String.t(), session_id: String.t()}`.

### ModelClient constructors

| Constructor | Provider | Default base URL |
|---|---|---|
| `ModelClient.new(model: "gpt-4o")` | `:openai` | `https://api.openai.com/v1` |
| `ModelClient.openai("gpt-4o")` | `:openai` | `https://api.openai.com/v1` |
| `ModelClient.anthropic("claude-sonnet-4-20250514")` | `:anthropic` | `https://api.anthropic.com` |
| `ModelClient.moonshot("moonshot-v1-8k")` | `:moonshot` | `https://api.moonshot.cn/v1` |

The named constructors (`openai/2`, `anthropic/2`, `moonshot/2`) take the model as the first argument and an optional keyword list as the second — e.g., `ModelClient.anthropic("claude-sonnet-4-20250514", api_key: "sk-...")`. `ModelClient.new/1` takes all options as keywords.

All constructors accept these options:

| Option | Type | Default | Description |
|---|---|---|---|
| `api_key` | `String.t()` | From env/config | API key (falls back to env var) |
| `base_url` | `String.t()` | Per-provider | Override API base URL |

### ModelClient.create/3 options

| Option | Type | Default | Description |
|---|---|---|---|
| `tools` | `[Tool.t()]` | `[]` | Tool schemas to send to the LLM |
| `temperature` | `float()` | Provider default | Model temperature (clamped to 0..1 for Moonshot/Anthropic) |
| `response_format` | `map()` | `nil` | Response format spec (ignored by Moonshot) |

### Sensing.sense/3 options

| Option | Type | Default | Description |
|---|---|---|---|
| `timeout` | `pos_integer()` | `30_000` | Per-tool timeout in milliseconds |
| `on_timeout` | `:kill_task \| :exit` | `:kill_task` | What to do when a tool times out |
| `intervention` | `[handler()]` | `[]` | Intervention handlers |
| `tools_map` | `map()` | `%{}` | `%{name => Tool}` for intervention lookups |
| `intervention_context` | `context()` | `%{iteration: 0, generated_messages: []}` | Context passed to intervention handlers |

### Intervention handler types

```elixir
# Module handler — implements @behaviour AgentEx.Intervention
defmodule MyHandler do
  @behaviour AgentEx.Intervention
  @impl true
  def on_call(call, tool, context), do: :approve
end

# Closure handler — 3-arity function
handler = fn call, tool, context -> :approve end
```

### Cross-reference

- [Architecture](../architecture.md) — OTP process diagrams and message flow
- [Modules](../modules.md) — Full API reference for all modules
- [Features](../features.md) — Feature comparison with AutoGen
- [Memory](../memory.md) — Deep dive into the 3-tier memory system
