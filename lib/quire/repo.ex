defmodule Quire.Repo do
  use Ecto.Repo,
    otp_app: :quire,
    adapter: Ecto.Adapters.Postgres
end
