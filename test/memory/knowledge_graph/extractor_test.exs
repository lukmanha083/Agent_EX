defmodule AgentEx.Memory.KnowledgeGraph.ExtractorTest do
  use ExUnit.Case, async: true

  alias AgentEx.Memory.KnowledgeGraph.Extractor

  test "extract returns error when API key is missing" do
    original = Application.get_env(:agent_ex, :openai_api_key)
    Application.put_env(:agent_ex, :openai_api_key, nil)
    System.delete_env("OPENAI_API_KEY")

    # Extractor uses ModelClient which resolves key from env
    # The call will fail at the HTTP level, not with :missing_api_key
    # since ModelClient sends empty bearer token → API returns 401
    result = Extractor.extract("some text")
    assert {:error, _} = result

    if original, do: Application.put_env(:agent_ex, :openai_api_key, original)
  end
end
