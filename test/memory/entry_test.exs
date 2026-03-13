defmodule AgentEx.Memory.EntryTest do
  use ExUnit.Case, async: true

  alias AgentEx.Memory.Entry

  test "new/3 creates entry with timestamps" do
    entry = Entry.new("lang", "elixir", "preference")
    assert entry.key == "lang"
    assert entry.value == "elixir"
    assert entry.type == "preference"
    assert %DateTime{} = entry.created_at
    assert %DateTime{} = entry.updated_at
  end
end
