defmodule AgentEx.Memory.MessageTest do
  use ExUnit.Case, async: true

  alias AgentEx.Memory.Message

  test "new/2 creates message with defaults" do
    msg = Message.new("user", "hello")
    assert msg.role == "user"
    assert msg.content == "hello"
    assert %DateTime{} = msg.timestamp
    assert msg.metadata == %{}
  end

  test "new/3 accepts metadata" do
    msg = Message.new("assistant", "hi", metadata: %{tool: "search"})
    assert msg.metadata == %{tool: "search"}
  end
end
