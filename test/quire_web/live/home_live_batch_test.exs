defmodule QuireWeb.HomeLiveBatchTest do
  use QuireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Quire.AccountsFixtures
  import Ecto.Query

  alias Quire.Repo

  @fixtures Path.expand("../../fixtures/pdfs", __DIR__)

  defp open_home(conn) do
    conn
    |> log_in_user(user_fixture())
    |> live(~p"/")
  end

  describe "Batch tile (T-087)" do
    test "appears in the tile grid and opens the recipe builder", %{conn: conn} do
      {:ok, lv, _html} = open_home(conn)

      assert has_element?(lv, ~s{div[phx-click="open_batch"]}, "Batch")

      lv |> element(~s{div[phx-click="open_batch"]}) |> render_click()

      assert has_element?(lv, ~s{div[role="dialog"][aria-label="Batch — recipe builder"]})
      assert has_element?(lv, "#batch-name")
      assert has_element?(lv, "#batch-run-btn[disabled]")
      # catalog steps are offered
      assert has_element?(lv, ~s{button[phx-click="batch_add_step"][phx-value-step="compress"]})
      assert has_element?(lv, ~s{button[phx-click="batch_add_step"][phx-value-step="pdfa"]})
    end

    test "steps can be added, saved as a recipe and reloaded", %{conn: conn} do
      {:ok, lv, _html} = open_home(conn)
      lv |> element(~s{div[phx-click="open_batch"]}) |> render_click()

      lv |> element("#batch-name") |> render_change(%{"name" => "Shrink"})

      lv
      |> element(~s{button[phx-click="batch_add_step"][phx-value-step="compress"]})
      |> render_click()

      lv
      |> element(~s{button[phx-click="batch_add_step"][phx-value-step="pdfa"]})
      |> render_click()

      assert render(lv) =~ "1. Compress"
      assert render(lv) =~ "2. PDF/A"

      lv |> element(~s{button[phx-click="batch_save_recipe"]}) |> render_click()

      # reload into a fresh modal
      lv
      |> element(~s{button[phx-click="close_batch"]:not([aria-label="Close"])})
      |> render_click()

      lv |> element(~s{div[phx-click="open_batch"]}) |> render_click()

      # the saved recipe appears in the load select
      html = render(lv)
      assert html =~ "Shrink"

      recipe = Quire.Repo.one!(from r in Quire.Batch.Recipe, where: r.name == "Shrink")
      lv |> element("#batch-load") |> render_change(%{"recipe" => recipe.id})

      assert render(lv) =~ "1. Compress"
      assert render(lv) =~ "2. PDF/A"
    end

    test "running a recipe queues one job per file per step", %{conn: conn} do
      {:ok, lv, _html} = open_home(conn)
      lv |> element(~s{div[phx-click="open_batch"]}) |> render_click()

      lv
      |> element(~s{button[phx-click="batch_add_step"][phx-value-step="compress"]})
      |> render_click()

      up1 =
        file_input(lv, "#batch-wizard", :batch_files, [
          %{name: "a.pdf", content: File.read!(Path.join(@fixtures, "simple_text.pdf"))}
        ])

      render_upload(up1, "a.pdf")

      up2 =
        file_input(lv, "#batch-wizard", :batch_files, [
          %{name: "b.pdf", content: File.read!(Path.join(@fixtures, "simple_text.pdf"))}
        ])

      render_upload(up2, "b.pdf")

      lv |> element("#batch-run-btn") |> render_click()

      jobs = Repo.all(from j in Oban.Job, where: j.worker == "Quire.Workers.BatchWorker")
      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.queue == "batch"))
      assert render(lv) =~ "Queued 2 batch job"
    end
  end
end
