defmodule Quire.Render.DegradedTest do
  use ExUnit.Case, async: true

  setup do
    # Just test that Render.Client returns unavailable for every operation
    # (no actual NIF mocking — the module is honest about its state)
    :ok
  end

  test "Render.Client.check/0 returns unavailable" do
    assert Quire.Render.Client.check() == {:error, "not available without browser"}
  end

  test "all Render.Client callbacks return unavailable" do
    client = Quire.Render.Client
    ref = :placeholder_ref

    assert client.page_count(ref) == {:error, :unavailable}
    assert client.page_geometry(ref) == {:error, :unavailable}
    assert client.render_page(ref, 0, []) == {:error, :unavailable}
    assert client.extract_text(ref, []) == {:error, :unavailable}
  end
end
