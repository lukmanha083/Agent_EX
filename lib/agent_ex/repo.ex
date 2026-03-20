defmodule AgentEx.Repo do
  use Ecto.Repo,
    otp_app: :agent_ex,
    adapter: Ecto.Adapters.Postgres
end
