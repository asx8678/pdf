u = %Quire.Accounts.User{id: Ecto.UUID.generate(), email: "x@y.z", hashed_password: "x"} |> Quire.Repo.insert!()
s = Quire.Accounts.Scope.for_user(u)
try do
  IO.inspect(s.id, label: "scope.id")
rescue
  e -> IO.puts("raised #{inspect(e.__struct__)}: #{Exception.message(e)}")
end
