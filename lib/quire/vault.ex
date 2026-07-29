defmodule Quire.Vault do
  @moduledoc """
  Cloak vault for at-rest encryption of sensitive columns.

  Configured at runtime — see `config/runtime.exs` for the production key
  or `config/dev.exs` / `config/test.exs` for environment-specific keys.
  """

  use Cloak.Vault, otp_app: :quire

  @impl GenServer
  def init(config) do
    config =
      if ciphers = Keyword.get(config, :ciphers) do
        Keyword.put(config, :ciphers, ciphers)
      else
        raise """
        Cloak ciphers not configured.

        Ensure :quire, #{inspect(__MODULE__)} has :ciphers in config.
        In dev/test, generate a key with:

            elixir -e 'IO.puts(Base.encode64(:crypto.strong_rand_bytes(32)))'
        """
      end

    {:ok, config}
  end
end
