defmodule AgentEx.Memory.EmbeddingsTest do
  use ExUnit.Case, async: true

  alias AgentEx.Memory.Embeddings

  test "embed returns error when API key is missing" do
    original = Application.get_env(:agent_ex, :openai_api_key)
    Application.put_env(:agent_ex, :openai_api_key, nil)

    # Also ensure env var doesn't interfere
    System.delete_env("OPENAI_API_KEY")

    assert {:error, :missing_api_key} = Embeddings.embed("test text")

    if original, do: Application.put_env(:agent_ex, :openai_api_key, original)
  end

  test "embed_batch returns error when API key is missing" do
    original = Application.get_env(:agent_ex, :openai_api_key)
    Application.put_env(:agent_ex, :openai_api_key, nil)
    System.delete_env("OPENAI_API_KEY")

    assert {:error, :missing_api_key} = Embeddings.embed_batch(["a", "b"])

    if original, do: Application.put_env(:agent_ex, :openai_api_key, original)
  end
end
