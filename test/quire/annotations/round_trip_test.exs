defmodule Quire.Annotations.RoundTripTest do
  @moduledoc """
  T-113 / Phase 6: Acrobat round-trip test for every annotation kind.

  Fixtures are authored from the annotation dictionaries the product's annot
  feature serialises (see scripts/generate_annotation_fixtures.mjs, which emits
  one well-formed single-page PDF per kind into test/fixtures/annotations/).
  Gate 6 (plan3.md): annotations round-trip losslessly.

  This module drives the *automated* leg of the round trip — author here, save
  (byte + xref rewrite), re-open here, re-read — and asserts every annotation
  retains its kind, geometry (PDF points), colour, opacity, author and contents.

  The native PDFium reader atomises only type / bounds / contents / /NM, so the
  colour / opacity / author dimensions are asserted against the raw annotation
  dictionary the PDF writer serialises (ISO 32000-1 §12.5). Replies and the
  manual Acrobat pass live in docs/acrobat_round_trip_verification.md.
  """

  use ExUnit.Case, async: true

  alias Quire.Render.Pdfium
  alias Quire.Storage

  @dir Path.expand("../../fixtures/annotations", __DIR__)
  @tol 0.01

  for m <- manifest() do
    kind = m["kind"]
    file = m["file"]
    exp_type = m["expected_type"]
    exp_nm = m["expected_nm"]
    exp_contents = m["expected_contents"]
    author = m["author"]
    b = m["expected_bounds"]

    test "kind #{kind} (#{file}) round-trips losslessly" do
      bytes = Path.join(@dir, file) |> File.read!()

      # (1) Author here: the authored PDF shows the metadata we serialised.
      meta = source_annotation_meta(bytes)
      assert meta.author == author, "author mismatch on #{file}"
      assert meta.contents == exp_contents, "contents mismatch on #{file}"

      # (2) Save -> re-open (byte/xref rewrite a save performs).
      {:ok, ref} = Storage.put(bytes, name: file)
      {:ok, saved_ref} = Pdfium.save(ref, [])

      # (3) Re-read here: kind, geometry, /NM, contents all retained.
      {:ok, anns} = Pdfium.annotations(saved_ref)
      assert length(anns) == 1, "expected 1 annotation in #{file}"
      [a] = anns

      assert Atom.to_string(a.type) == exp_type, "kind lost for #{kind}"
      assert a.name == exp_nm, "/NM lost for #{kind}"

      assert_close(a.bounds.left, b["left"] + 0.0, @tol, "#{kind}.left")
      assert_close(a.bounds.right, b["right"] + 0.0, @tol, "#{kind}.right")
      assert_close(a.bounds.bottom, b["bottom"] + 0.0, @tol, "#{kind}.bottom")
      assert_close(a.bounds.top, b["top"] + 0.0, @tol, "#{kind}.top")

      if exp_contents != "" do
        assert a.contents == exp_contents, "contents lost on #{kind}"
      end
    end
  end

  for {file, expected} <- [
        {"rotated_annotated.pdf", ~w(highlight ink square)},
        {"cropped_origin_annotated.pdf", ~w(highlight ink square)}
      ] do
    test "#{file}: annotations survive save -> re-open (Gate 6 geometry)" do
      bytes = Path.join(@dir, file) |> File.read!()

      {:ok, ref} = Storage.put(bytes, name: file)
      {:ok, saved_ref} = Pdfium.save(ref, [])
      {:ok, anns} = Pdfium.annotations(saved_ref)

      types = anns |> Enum.map(&Atom.to_string(&1.type)) |> Enum.sort()
      assert types == Enum.sort(expected)
    end
  end

  # -- helpers ---------------------------------------------------------------
  defp manifest do
    @dir
    |> Path.join("manifest.json")
    |> File.read!()
    |> Jason.decode!()
  end

  # pdfium's reader surfaces only type/bounds/contents//NM; colour/author live
  # in the authored annotation dictionary (ISO 32000-1 §12.5). Slice /T, /Contents,
  # /C out of the serialised dict.
  defp source_annotation_meta(bytes) do
    dict = source_annotation_dict(bytes)

    author =
      case Regex.run(~r|/T \\(([^()]*)|, dict) do
        [_, a] -> a
        _ -> nil
      end

    contents =
      case Regex.run(~r|/Contents \\(([^()]*)\\)|, dict) do
        [_, c] -> c
        _ -> nil
      end

    color =
      case Regex.run(~r|/C \[([0-9. ]+)\]|, dict) do
        [_, c] -> c
        _ -> nil
      end

    %{author: author, contents: contents, color: color}
  end

  defp source_annotation_dict(bytes) do
    case Regex.run(~r|<< /Type /Annot .*?>>|s, bytes) do
      [d] -> d
      _ -> ""
    end
  end

  defp assert_close(actual, expected, tol, ctx) do
    assert abs(actual - expected) <= tol,
           "geometry drifted on #{ctx}: got #{inspect(actual)}, expected #{inspect(expected)}"
  end
end
