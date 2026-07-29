ExUnit.start()

if function_exported?(Ecto.Adapters.SQL.Sandbox, :mode, 2) do
  try do
    Ecto.Adapters.SQL.Sandbox.mode(Quire.Repo, :manual)
  rescue
    _ -> :ok
  end
end
