defmodule AgentEx.CodeQualityTest do
  use ExUnit.Case, async: true

  @moduletag :code_quality

  describe "ex_slop (Credo)" do
    test "no AI anti-patterns or code smells in lib/" do
      {output, exit_code} = System.cmd("mix", ["credo", "--strict", "--format", "json"],
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

      case Jason.decode(output) do
        {:ok, %{"issues" => issues}} ->
          assert issues == [],
            "Credo/ExSlop found #{length(issues)} issue(s):\n\n" <>
              format_credo_issues(issues)

        _ ->
          assert exit_code == 0,
            "mix credo --strict failed (exit #{exit_code}):\n#{output}"
      end
    end
  end

  describe "ex_dna" do
    test "no code duplication in lib/" do
      report = ExDNA.analyze("lib/")

      assert report.clones == [],
        "ExDNA found #{length(report.clones)} clone(s). Run `mix ex_dna` for details."
    end
  end

  defp format_credo_issues(issues) do
    Enum.map_join(issues, "\n", fn issue ->
      file = issue["filename"] || "?"
      line = issue["line_no"] || "?"
      msg = issue["message"] || "?"
      check = issue["check"] || "?"
      "  #{file}:#{line} [#{check}] #{msg}"
    end)
  end
end
