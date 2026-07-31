ExUnit.start(exclude: [:broken])

# Force compilation of support modules before any test file tries to use them.
# Elixir 1.20 parallel compilation can otherwise race and fail to load
# CaseTemplate-based modules at compile time.
for path <- [
      "test/support/data_case.ex",
      "test/support/conn_case.ex",
      "test/support/fixtures/accounts_fixtures.ex"
    ] do
  Code.compile_file(path)
end

if function_exported?(Ecto.Adapters.SQL.Sandbox, :mode, 2) do
  try do
    Ecto.Adapters.SQL.Sandbox.mode(Quire.Repo, :manual)
  rescue
    _ -> :ok
  end
end
