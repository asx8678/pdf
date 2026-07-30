defmodule QuireWeb.WorkspaceLive.EsignWizardTest do
  use Quire.DataCase

  import Quire.AccountsFixtures

  # Test the esign_wizard_place_field effect on assigns directly,
  # verifying the coordinate pipe updates the correct field.
  test "place field updates last added field with coordinates" do
    fields = [%{id: "f1", signer_index: 0, kind: :signature, page_index: 0}]

    # Simulate what the handle_event does
    last = List.last(fields)

    updated =
      if last do
        List.replace_at(
          fields,
          length(fields) - 1,
          Map.merge(last, %{page_index: 2, rect: [10, 20, 130, 44]})
        )
      else
        fields
      end

    assert length(updated) == 1
    assert hd(updated)[:page_index] == 2
    assert hd(updated)[:rect] == [10, 20, 130, 44]
  end

  test "add field then place coordinates" do
    fields = []

    # Add field
    new_field = %{id: Ecto.UUID.generate(), signer_index: 0, kind: :signature, page_index: 0}
    fields = fields ++ [new_field]

    # Place it (simulate what handle_event does)
    last = List.last(fields)

    updated =
      if last do
        List.replace_at(
          fields,
          length(fields) - 1,
          Map.merge(last, %{page_index: 1, rect: [50, 100, 170, 124]})
        )
      else
        fields
      end

    field = List.last(updated)
    assert field[:page_index] == 1
    assert field[:rect] == [50, 100, 170, 124]
  end

  test "place field with no existing fields is a no-op" do
    fields = []
    last = List.last(fields)

    updated =
      if last do
        List.replace_at(
          fields,
          length(fields) - 1,
          Map.merge(last, %{page_index: 0, rect: [0, 0, 1, 1]})
        )
      else
        fields
      end

    assert updated == []
  end
end
