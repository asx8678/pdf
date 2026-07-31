defmodule Quire.Batch do
  @moduledoc ~S"""
  Batch runner and recipe builder (§9.2, T-087).

  A recipe is an ordered list of steps — the Create & Convert operations with
  their options — that can be saved, re-loaded and run against N files. Each
  (file, step) pair is enqueued as one Oban job on the `:batch` queue
  (concurrency 1, §7.5), and every job writes its own `operations` row with
  live progress (T-086).

  ## Step catalog

    * `{"compress", %{preset: "medium"}}` — recompress embedded images
    * `{"pdfa", %{}}` — best-effort PDF/A-2b conversion
    * `{"split", %{every_n: "5"}}` — split into N-page parts (ZIP)
    * `{"image_to_pdf", %{deskew: true, contrast: "auto"}}` — image → PDF
  """

  alias Quire.Repo

  @doc "Returns the steps a recipe can contain."
  @spec steps_catalog() :: [map()]
  def steps_catalog do
    [
      %{
        id: "compress",
        label: "Compress",
        desc: "Recompress embedded images",
        opts: [preset: "medium"]
      },
      %{id: "pdfa", label: "PDF/A", desc: "Best-effort PDF/A-2b conversion", opts: []},
      %{id: "split", label: "Split", desc: "Split into N-page parts", opts: [every_n: "5"]},
      %{
        id: "image_to_pdf",
        label: "Image to PDF",
        desc: "Scan an image into a PDF",
        opts: [deskew: true, contrast: "auto"]
      }
    ]
  end

  @doc "Creates a recipe for a user. Returns `{:ok, %Recipe{}}` or `{:error, changeset}`."
  @spec create_recipe(binary(), String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def create_recipe(user_id, name, steps) when is_binary(user_id) do
    %Quire.Batch.Recipe{user_id: user_id, name: name, steps: steps}
    |> Quire.Batch.Recipe.changeset(%{name: name, steps: steps})
    |> Repo.insert()
  end

  @doc "Lists the user's recipes."
  @spec list_recipes(binary()) :: [map()]
  def list_recipes(user_id) do
    import Ecto.Query

    Repo.all(from r in Quire.Batch.Recipe, where: r.user_id == ^user_id, order_by: [asc: r.name])
  end

  @doc "Fetches a recipe owned by the user."
  @spec get_recipe(binary(), binary()) :: {:ok, map()} | {:error, term()}
  def get_recipe(id, user_id) do
    case Repo.get(Quire.Batch.Recipe, id) do
      %Quire.Batch.Recipe{user_id: ^user_id} = recipe -> {:ok, recipe}
      %Quire.Batch.Recipe{} -> {:error, :forbidden}
      nil -> {:error, :not_found}
    end
  end

  @doc "Deletes a recipe owned by the user."
  @spec delete_recipe(binary(), binary()) :: :ok | {:error, term()}
  def delete_recipe(id, user_id) do
    case get_recipe(id, user_id) do
      {:ok, recipe} ->
        Repo.delete(recipe)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Runs a recipe against a list of files.

  Enqueues one `Quire.Workers.BatchWorker` job per (file, step) pair on the
  `:batch` queue. Returns `{:ok, count}`.
  """
  @spec run_recipe(binary(), String.t(), [map()], [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def run_recipe(user_id, recipe_name, steps, files) when is_list(files) do
    jobs =
      for %{name: filename, bytes: bytes} <- files, step <- steps do
        Quire.Workers.BatchWorker.new(%{
          "user_id" => user_id,
          "recipe" => recipe_name,
          "filename" => filename,
          "bytes" => Base.encode64(bytes),
          "step" => step
        })
      end

    Oban.insert_all(jobs)
    {:ok, length(jobs)}
  end
end
