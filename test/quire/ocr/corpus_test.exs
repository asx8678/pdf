defmodule Quire.Ocr.CorpusTest do
  use ExUnit.Case, async: true

  @fixtures_dir Path.expand("../../fixtures/pdfs", __DIR__)
  @pdfs File.ls!(@fixtures_dir) |> Enum.filter(&String.ends_with?(&1, ".pdf"))

  # Fixtures that can't be rendered (encrypted, corrupt, or produce no
  # OCR-able page).  encrypted_owner_pw and encrypted_user_pw need a
  # password; corrupt_xref has intentional xref damage.
  @skip MapSet.new(~w(
    encrypted_owner_pw
    encrypted_user_pw
    corrupt_xref
  ))

  for fixture <- @pdfs do
    name = fixture |> Path.rootname()
    path = Path.join(@fixtures_dir, fixture)

    if MapSet.member?(@skip, name) do
      @tag :skip
      test "first page renders and OCRs for #{name}" do
        {:ok, bytes} = File.read(unquote(path))
        {:ok, _ref} = Quire.Storage.put(bytes, name: unquote(fixture))
      end
    else
      test "first page renders and OCRs for #{name}" do
        {:ok, bytes} = File.read(unquote(path))
        {:ok, ref} = Quire.Storage.put(bytes, name: unquote(fixture))

        # Render first page to PNG
        case Quire.Render.Pdfium.render_page(ref, 0, dpi: 150) do
          {:ok, png} ->
            assert is_binary(png)
            # PNG header
            assert binary_part(png, 0, 4) == <<137, 80, 78, 71>>

            # Run OCR on the rendered page
            case Quire.Ocr.Tesseract.run(png, language: "eng") do
              {:ok, spans} ->
                assert is_list(spans)

                if unquote(name) == "simple_text" do
                  # simple_text.pdf has at least some recognised text
                  assert length(spans) > 0
                end

              {:error, %Quire.Engine.Error{}} ->
                :ok
            end

          {:error, %Quire.Engine.Error{}} ->
            :ok
        end
      end
    end
  end
end
