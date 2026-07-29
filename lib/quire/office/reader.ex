defmodule Quire.Office.Reader do
  @moduledoc """
  Dispatches office document reading by file type.

  The reader takes raw bytes (obtained through `Storage`, per T-014) and returns
  a `Quire.Office.Layout.t()` struct that can be rendered to HTML.

  ## Supported formats

    * `.docx` — Word (T-069)
    * `.xlsx` — Excel (T-070)
    * `.pptx` — PowerPoint (T-070)
    * `.odt`, `.ods`, `.odp` — OpenDocument (T-071)
    * `.rtf` — Rich Text Format (T-071)
    * `.csv`, `.txt`, `.md` — plain text
  """

  @doc """
  Read an office document from bytes.

  The `filename` is used to detect the format by extension. Returns
  `{:ok, Quire.Office.Layout.t()}` or `{:error, :unknown_format}` for an
  unrecognised extension.

  ## Examples

      {:ok, layout} = Quire.Office.Reader.read(File.read!("report.docx"), "report.docx")
      {:ok, layout} = Quire.Office.Reader.read(File.read!("budget.xlsx"), "budget.xlsx")
  """
  @spec read(binary(), String.t()) :: {:ok, Quire.Office.Layout.t()} | {:error, atom()}
  def read(bytes, filename) when is_binary(bytes) and is_binary(filename) do
    case format(filename) do
      :xlsx ->
        Quire.Office.Reader.Xlsx.read(bytes)

      :pptx ->
        Quire.Office.Reader.Pptx.read(bytes)

      :ods ->
        Quire.Office.Reader.Ods.read(bytes)

      :odt ->
        Quire.Office.Reader.Odt.read(bytes)

      :odp ->
        Quire.Office.Reader.Odp.read(bytes)

      :rtf ->
        Quire.Office.Reader.Rtf.read(bytes)

      :unknown ->
        {:error, :unknown_format}
    end
  end

  defp format(filename) do
    case String.downcase(Path.extname(filename)) do
      ".xlsx" -> :xlsx
      ".pptx" -> :pptx
      ".docx" -> :docx
      ".odt" -> :odt
      ".ods" -> :ods
      ".odp" -> :odp
      ".rtf" -> :rtf
      ".csv" -> :csv
      ".txt" -> :txt
      ".md" -> :md
      _ -> :unknown
    end
  end
end
