# Quality Gate

Run the project's static analysis and code quality checks, then report and fix any issues found.

## Instructions

You are running AgentEx's quality gate pipeline. Execute these steps in order:

### Step 1: Run all quality checks in parallel

Run these three commands simultaneously:

1. **Credo + ExSlop** (strict mode, JSON output):
   ```
   mix credo --strict --format json
   ```

2. **ExDNA** clone detection:
   ```
   mix ex_dna
   ```

3. **Elixir compiler warnings** (type checking + unused vars + pattern match):
   ```
   mix compile --warnings-as-errors --force
   ```

### Step 2: Report findings

For each tool, summarize the results:
- **Credo/ExSlop**: Group issues by category (Warning, Refactor, Readability, Consistency). Show file:line and the check name.
- **ExDNA**: List any detected clones with file locations and similarity %.
- **Compiler**: List any type warnings or other diagnostics.

If all checks pass, report a clean bill of health and stop here.

### Step 3: Fix issues

If issues were found:
1. Read each affected file
2. Fix the issues — prioritize Warnings > Refactoring > Readability
3. For ExDNA clones: extract shared logic into a helper only if the duplication is meaningful (3+ occurrences or >30 lines); otherwise note it and move on
4. Run `mix format` on changed files
5. Re-run the failing checks to confirm they pass

### What NOT to do
- Do not add `@spec` annotations unless the fix specifically requires it (Credo.Check.Readability.Specs is disabled)
- Do not refactor code beyond what the checks require
- Do not modify tests unless a check flags test code specifically

$ARGUMENTS
