defmodule AgentEx.Tools.WebFetchTest do
  use ExUnit.Case, async: true

  alias AgentEx.Tools.WebFetch

  describe "tool/1" do
    test "returns a valid Tool struct" do
      tool = WebFetch.tool()
      assert tool.name == "web_fetch"
      assert tool.kind == :read
      assert is_function(tool.function, 1)
    end

    test "accepts max_length option" do
      tool = WebFetch.tool(max_length: 500)
      assert tool.name == "web_fetch"
    end
  end

  describe "strip_html/1" do
    test "removes HTML tags" do
      assert WebFetch.strip_html("<p>Hello</p>") == "Hello"
    end

    test "removes script and style blocks" do
      html = "<script>alert('x')</script><style>.a{}</style><p>Text</p>"
      assert WebFetch.strip_html(html) == "Text"
    end

    test "normalizes whitespace" do
      html = "<p>Hello</p>   <p>World</p>"
      assert WebFetch.strip_html(html) == "Hello World"
    end

    test "handles HTML entities" do
      assert WebFetch.strip_html("A&amp;B&lt;C") == "A B C"
    end

    test "handles empty string" do
      assert WebFetch.strip_html("") == ""
    end
  end
end
