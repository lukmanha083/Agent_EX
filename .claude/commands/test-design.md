# ExUnit Test Design

Design and write ExUnit tests for AgentEx modules, then validate them against the quality gates.

## Instructions

You are designing ExUnit tests for the AgentEx project. Follow this workflow:

### Step 1: Understand the target

Read the module(s) specified in the arguments. If no arguments given, identify modules in `lib/` that lack corresponding test files in `test/`.

Analyze:
- Public API surface (all public functions)
- Edge cases from pattern matching clauses
- GenServer callbacks and state transitions
- Behaviour implementations (Tier, Transport, Intervention)
- Error paths and boundary conditions

### Step 2: Review existing test patterns

Read 2-3 existing test files to match the project's conventions:
- `test/swarm_test.exs` — complex GenServer + mock model patterns
- `test/intervention_test.exs` — behaviour testing + pipeline patterns
- `test/mcp/client_test.exs` — MockTransport pattern for behaviours

Key conventions to follow:
- Use `async: true` unless the test needs named GenServers or shared ETS/DETS state
- Mock LLM responses with `Agent`-based stateful helpers (see `mock_model/1` pattern in swarm_test)
- Mock behaviours with in-test modules (see `MockTransport` pattern)
- No `Mox` library — use plain process-based stubs
- Tag integration tests or slow tests with `@moduletag`
- Group related tests in `describe` blocks

### Step 3: Write the tests

Write comprehensive tests covering:
1. **Happy path** — normal operation with expected inputs
2. **Edge cases** — empty inputs, nil values, boundary values
3. **Error cases** — invalid arguments, process crashes, timeouts
4. **State transitions** — for GenServer modules, test state before/after
5. **Concurrency** — where relevant, test parallel access patterns

### Step 4: Run the quality gate pipeline

After writing tests, run these checks in parallel:

1. **Run the new tests**:
   ```
   mix test <test_file_path> --trace
   ```

2. **Credo + ExSlop on the new test file**:
   ```
   mix credo --strict --files-included <test_file_path>
   ```

3. **Compile check**:
   ```
   mix compile --warnings-as-errors
   ```

Fix any issues found and re-run until clean.

### Step 5: Run the full test suite

```
mix test
```

Ensure no regressions. If tests fail, investigate and fix before finishing.

### What NOT to do
- Do not test private functions directly — test through the public API
- Do not add `@moduledoc` or `@doc` to test modules
- Do not over-mock — prefer testing real module interactions where feasible
- Do not create test helper modules unless shared by 3+ test files

$ARGUMENTS
