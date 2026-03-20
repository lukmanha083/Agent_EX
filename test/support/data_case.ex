defmodule AgentEx.DataCase do
  @moduledoc "Test case for Ecto database tests with sandbox isolation."

  use ExUnit.CaseTemplate

  using do
    quote do
      alias AgentEx.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import AgentEx.DataCase
    end
  end

  setup tags do
    AgentEx.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    alias Ecto.Adapters.SQL.Sandbox
    pid = Sandbox.start_owner!(AgentEx.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
