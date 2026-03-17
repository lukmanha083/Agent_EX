# Code Review (Feature Branch)

Run a comprehensive code review scoped to the current feature branch, combining CodeRabbit AI review with local quality gates and manual analysis.

## Instructions

You are performing a scoped code review on the current feature branch against `main`. Follow this workflow:

### Step 1: Identify branch and changes

1. Confirm the current branch and that it differs from `main`:
   ```
   git branch --show-current
   git log main..HEAD --oneline
   git diff main --stat
   ```

2. If there are no commits yet on the branch, review uncommitted/staged changes:
   ```
   git diff main --stat
   git diff --cached --stat
   ```

### Step 2: CodeRabbit AI review (feature branch scope)

Run CodeRabbit CLI scoped to only the feature branch changes:

1. **Full review with detailed feedback**:
   ```
   cr --base main --plain
   ```

2. If the branch has both committed and uncommitted changes, run separately for clarity:
   ```
   cr --base main --type committed --plain
   cr --base main --type uncommitted --plain
   ```

3. If CodeRabbit is not installed, inform the user and continue with Steps 3-4. Suggest:
   ```
   curl -fsSL https://cli.coderabbit.ai/install.sh | sh
   ```

### Step 3: Run local quality gates in parallel

Run these checks simultaneously, scoped to changed files where possible:

1. **Credo + ExSlop** (strict mode):
   ```
   mix credo --strict --format json
   ```

2. **ExDNA** clone detection:
   ```
   mix ex_dna
   ```

3. **Compiler warnings**:
   ```
   mix compile --warnings-as-errors --force
   ```

4. **Test suite**:
   ```
   mix test
   ```

### Step 4: Manual review of changed files

Read each file changed on the feature branch (`git diff main --name-only`) and review for:

**Correctness**
- Pattern match exhaustiveness
- Proper error handling (tagged tuples, not exceptions for expected failures)
- GenServer state consistency (no partial state updates that could crash)
- Process lifecycle (links vs monitors, cleanup on termination)

**OTP Patterns**
- GenServer calls vs casts used appropriately
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
- External HTTP calls use proper timeouts
- `CodeRunner` tool inputs validated/sandboxed

**Documentation** (for doc changes)
- Accuracy against current module source code
- No stale references to removed or renamed modules/functions
- Code examples are syntactically valid

### Step 5: Consolidated report

Combine CodeRabbit findings with local quality gate results and manual review into a single report:

1. **CodeRabbit Findings** — summarize key issues and suggestions from the AI review
2. **Bugs / Must Fix** — incorrect behavior, crashes, data loss risks
3. **Quality Gate Failures** — Credo/ExSlop/ExDNA/compiler issues
4. **Suggestions** — improvements that aren't blocking

For each finding, include the file:line reference and a concrete fix suggestion.

### Step 6: Fix (if requested)

If the user passes `--fix` in arguments or asks to fix issues:
1. Fix all items from categories 1-2 (CodeRabbit critical + Bugs)
2. Fix all quality gate failures
3. Apply non-controversial suggestions
4. Run `mix format` on changed files
5. Re-run quality gates to confirm clean
6. Do NOT create a commit — leave changes staged for the user

$ARGUMENTS
