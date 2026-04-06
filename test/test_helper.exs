{:ok, _} = Application.ensure_all_started(:wallaby)
File.mkdir_p!("/tmp/agent_ex_test")
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(AgentEx.Repo, :manual)
