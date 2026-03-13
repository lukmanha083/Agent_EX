defmodule AgentEx.Memory.ContextMessageTest do
  use ExUnit.Case, async: true

  alias AgentEx.Memory.ContextMessage

  test "system/1 creates system message" do
    msg = ContextMessage.system("you are helpful")
    assert msg.role == "system"
    assert msg.content == "you are helpful"
  end

  test "user/1 creates user message" do
    msg = ContextMessage.user("hello")
    assert msg.role == "user"
  end

  test "assistant/1 creates assistant message" do
    msg = ContextMessage.assistant("hi there")
    assert msg.role == "assistant"
  end
end
