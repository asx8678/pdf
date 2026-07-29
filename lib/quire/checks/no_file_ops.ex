defmodule Quire.Checks.NoFileOps do
  @moduledoc """
  Flags usage of `File.`, `Path.`, `System.cmd`, and `System.tmp_dir`
  outside allowed source files.

  The following paths are exempt:
    - `lib/quire/storage.ex`
    - `lib/quire/storage/*.ex`
    - `lib/quire/engine.ex`
    - `test/support/*.ex`
  """

  use Credo.Check,
    base_priority: :high,
    category: :custom

  Module.register_attribute(__MODULE__, :check_name, persist: true)
  @check_name "Quire.Checks.NoFileOps"

  @allowed_prefixes [
    "lib/quire/storage.ex",
    "lib/quire/storage/",
    "lib/quire/engine.ex",
    "test/support/"
  ]

  @skip_prefixes ["deps/", "_build/"]

  @pattern ~r{(?:File\.|Path\.(?!t\()|System\.cmd|System\.tmp_dir)}

  @doc false
  @impl true
  def run(%SourceFile{filename: filename} = source_file, params) do
    cond do
      Enum.any?(@skip_prefixes, &String.starts_with?(filename, &1)) ->
        []

      Enum.any?(@allowed_prefixes, &String.starts_with?(filename, &1)) ->
        []

      true ->
        issue_meta = IssueMeta.for(source_file, params)

        source_file
        |> SourceFile.lines()
        |> Enum.reduce([], fn {line_no, line}, issues ->
          case Regex.run(@pattern, line) do
            nil ->
              issues

            [match | _] ->
              [
                format_issue(
                  issue_meta,
                  message:
                    "File/Path/System operation outside allowed files: #{match}",
                  line_no: line_no,
                  trigger: match
                )
                | issues
              ]
          end
        end)
        |> Enum.reverse()
    end
  end
end
