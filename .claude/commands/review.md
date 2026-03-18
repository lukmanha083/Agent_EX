# Code Review

Review changed code for correctness, OTP patterns, and quality gate compliance.

## Instructions

You are performing a code review on AgentEx. Follow this workflow:

### Step 1: Identify changes

Run `git diff` (or `git diff --cached` if staged) to see what changed. If a specific file or PR is given in arguments, review that instead.

### Step 2: Run quality gates in parallel

1. **Credo + ExSlop** (strict mode):
   ```bash
   mix credo --strict --format json
   ```

2. **ExDNA** clone detection:
   ```bash
   mix ex_dna
   ```

3. **Compiler warnings**:
   ```bash
   mix compile --warnings-as-errors --force
   ```

4. **Test suite**:
   ```bash
   mix test
   ```

### Step 3: Manual review

Read each changed file and review for:

**Correctness**
- Pattern match exhaustiveness
- Proper error handling (tagged tuples, not exceptions for expected failures)
- GenServer state consistency (no partial state updates that could crash)
- Process lifecycle (links vs monitors, cleanup on termination)

**OTP Patterns**
- GenServer calls vs casts used appropriately (call for queries, cast for fire-and-forget)
- Supervisor strategy matches child behavior
- No blocking calls in GenServer `init/1`
- Task.async properly awaited or supervised

**AgentEx Conventions**
- Tool functions return `{:ok, result}` or `{:error, reason}`
- Tool kind (`:read`/`:write`/`:builtin`) correctly assigned
- Messages use proper `AgentEx.Message` structs
- Memory operations scoped by `agent_id`

**Security**
- No secrets or API keys hardcoded
- `CodeRunner` tool inputs validated/sandboxed
- External HTTP calls use proper timeouts

### Step 4: Report

Present findings grouped by severity:
1. **Bugs / Must Fix** — incorrect behavior, crashes, data loss risks
2. **Quality Gate Failures** — Credo/ExSlop/ExDNA/compiler issues
3. **Suggestions** — improvements that aren't blocking

For each finding, include the file:line reference and a concrete fix suggestion.

$ARGUMENTS
