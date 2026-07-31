defmodule Quire.Forms.AutoCreate do
  @moduledoc """
  Auto-create fields from a scanned form (§9.8, T-125).

  Detection (`Quire.Forms.Detect`) runs in a background job so the LiveView
  stays responsive; this module owns the commit half: turning a set of
  detections into real AcroForm fields in a new PDF revision.

  ## Flow

    1. `Detect.detect_ref/2` — heuristic line/box detection over every page
       (background job, progress reported).
    2. Detections are shown to the user as a preview.
    3. `commit/3` — accepted detections become real `/FT` fields via
       `Quire.Pdf.AcroForm.add_field/5`, saved and stored as a new revision.
  """

  alias Quire.Pdf
  alias Quire.Pdf.AcroForm
  alias Quire.Storage.Ref

  @doc """
  Builds a new PDF binary with one AcroForm field per detection.

  `detections` is a list of `%{kind: :text | :checkbox, page_index: int,
  rect: [x0, y0, x1, y1]}` (the shape `Quire.Forms.Detect` returns).
  Field names are generated as `<kind><n>` (e.g. `text1`, `checkbox2`).

  Returns `{:ok, pdf_bytes}`.  The input bytes are untouched.
  """
  @spec commit(binary(), [map()]) :: {:ok, binary()} | {:error, term()}
  def commit(pdf_bytes, detections) when is_binary(pdf_bytes) and is_list(detections) do
    with {:ok, doc} <- Pdf.open(pdf_bytes) do
      result =
        detections
        |> Enum.with_index(1)
        |> Enum.reduce_while(:ok, fn {det, i}, :ok ->
          name = "#{det.kind}#{i}"
          kind = if det.kind == :checkbox, do: :checkbox, else: :text

          case AcroForm.add_field(doc, det.page_index, det.rect, name, kind) do
            {:ok, _ref} -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
        end)

      case result do
        :ok ->
          Pdf.save(doc)

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Commits detections and persists the result as a new revision of `doc`,
  switching the document's current revision pointer to it.

  Returns `{:ok, %{revision: rev, bytes: pdf_bytes}}`.
  """
  @spec commit_revision(map(), [map()]) :: {:ok, map()} | {:error, term()}
  def commit_revision(doc, detections) do
    with {:ok, rev} <- Quire.Documents.current_revision(doc),
         %Ref{} = ref <- Quire.Documents.Revision.storage_ref(rev),
         {:ok, source_bytes} <- Quire.Storage.get(ref),
         {:ok, pdf_bytes} <- commit(source_bytes, detections) do
      label = "Auto-create fields (#{Date.utc_today()})"

      {:ok, new_ref} =
        Quire.Storage.put(pdf_bytes, name: doc.title || "form", content_type: "application/pdf")

      source_map = %{
        "storage_ref" => %{
          "adapter" => to_string(new_ref.adapter),
          "key" => new_ref.key,
          "name" => new_ref.name,
          "content_type" => new_ref.content_type,
          "byte_size" => new_ref.byte_size
        },
        "filename" => doc.title || "form.pdf"
      }

      {:ok, new_rev} = Quire.Documents.create_revision(doc, label: label, source: source_map)

      {:ok, _updated} =
        doc
        |> Ecto.Changeset.change(%{current_revision_id: new_rev.id})
        |> Quire.Repo.update()

      Phoenix.PubSub.broadcast(
        Quire.PubSub,
        "document:#{doc.id}",
        {:revision, new_rev}
      )

      {:ok, %{revision: new_rev, bytes: pdf_bytes}}
    else
      nil -> {:error, :no_storage_ref}
      {:error, _} = err -> err
    end
  end
end
