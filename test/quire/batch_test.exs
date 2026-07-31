defmodule Quire.BatchTest do
  use QuireWeb.ConnCase, async: true

  import Quire.AccountsFixtures

  alias Quire.Batch

  @fixtures Path.expand("../fixtures/pdfs", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  describe "recipe CRUD" do
    test "create, list, fetch and delete recipes" do
      user = user_fixture()
      steps = [%{"id" => "compress", "preset" => "medium"}, %{"id" => "pdfa"}]

      assert {:ok, recipe} = Batch.create_recipe(user.id, "Shrink", steps)
      assert recipe.name == "Shrink"
      assert recipe.steps == steps

      assert [recipe] = Batch.list_recipes(user.id)

      assert {:ok, ^recipe} = Batch.get_recipe(recipe.id, user.id)
      assert {:error, :not_found} = Batch.get_recipe(Ecto.UUID.generate(), user.id)

      assert :ok = Batch.delete_recipe(recipe.id, user.id)
      assert Batch.list_recipes(user.id) == []
    end

    test "duplicate names are rejected", %{conn: _conn} do
      user = user_fixture()
      assert {:ok, _} = Batch.create_recipe(user.id, "Same", [%{"id" => "pdfa"}])
      assert {:error, _} = Batch.create_recipe(user.id, "Same", [%{"id" => "pdfa"}])
    end
  end

  describe "steps catalog" do
    test "exposes the batch-able operations" do
      ids = Batch.steps_catalog() |> Enum.map(& &1.id)
      assert ids == ["compress", "pdfa", "split", "image_to_pdf"]
    end
  end

  describe "BatchWorker" do
    test "compress step produces a valid PDF" do
      bytes = fixture("50mb_images.pdf")
      step = %{"id" => "compress", "preset" => "high"}

      assert {:ok, out} = Quire.Workers.BatchWorker.apply_step(bytes, step, "images.pdf")
      assert binary_part(out, 0, 5) == "%PDF-"
      assert byte_size(out) < byte_size(bytes)
    end

    test "pdfa step produces a PDF/A document" do
      step = %{"id" => "pdfa"}

      assert {:ok, out} =
               Quire.Workers.BatchWorker.apply_step(
                 fixture("simple_text.pdf"),
                 step,
                 "simple.pdf"
               )

      assert binary_part(out, 0, 5) == "%PDF-"
      assert {:ok, %{checks: checks}} = Quire.PdfA.validate(out)
      assert Enum.any?(checks, &(&1.name == "ICC OutputIntent" and &1.status == :pass))
    end
  end

  describe "run_recipe/4" do
    test "queues one job per file per step on the :batch queue" do
      user = user_fixture()
      steps = [%{"id" => "compress"}, %{"id" => "pdfa"}]

      files = [
        %{name: "a.pdf", bytes: fixture("simple_text.pdf")},
        %{name: "b.pdf", bytes: fixture("simple_text.pdf")}
      ]

      assert {:ok, 4} = Batch.run_recipe(user.id, "Test", steps, files)

      import Ecto.Query
      jobs = Quire.Repo.all(from j in Oban.Job, where: j.worker == "Quire.Workers.BatchWorker")
      assert length(jobs) == 4
      assert Enum.all?(jobs, &(&1.queue == "batch"))
      assert Enum.all?(jobs, &(&1.worker == "Quire.Workers.BatchWorker"))
    end

    test "respects the §7.5 laptop-sized batch concurrency (queue limit 1)" do
      # the batch queue is a literal constant of 1 in the Oban config — N
      # files never spawn more than one conversion at a time on :batch
      queues = Keyword.fetch!(Application.get_env(:quire, Oban), :queues)
      assert queues[:batch] == 1
    end
  end
end
