defmodule Quire.NifFuzzTest do
  use ExUnit.Case, async: false

  # Collect every fixture file across pdfs, images and texts
  @fixture_dirs [
    Path.expand("../fixtures/pdfs", __DIR__),
    Path.expand("../fixtures/images", __DIR__),
    Path.expand("../fixtures/texts", __DIR__)
  ]

  @all_fixtures Enum.flat_map(@fixture_dirs, fn dir ->
    for f <- File.ls!(dir), not File.dir?(Path.join(dir, f)), do: Path.join(dir, f)
  end)

  @mb 1024 * 1024

  describe "ExPdfium.open_blob crash-fuzz" do
    for path <- @all_fixtures do
      fname = Path.basename(path)
      size = File.stat!(path).size
      skip_big = size > 500 * @mb

      if skip_big do
        @tag :skip
        test "open_blob does not crash on #{fname}" do
          {:ok, _bytes} = File.read(unquote(path))
        end
      else
        test "open_blob does not crash on #{fname}" do
          {:ok, bytes} = File.read(unquote(path))

          result =
            try do
              case ExPdfium.open_blob(bytes) do
                {:ok, doc} ->
                  ExPdfium.close(doc)
                  {:ok, :opened}

                {:error, reason} ->
                  {:ok, {:error, reason}}
              end
            rescue
              e -> {:crash, Exception.message(e)}
            catch
              :exit, reason -> {:crash, {:exit, reason}}
            end

          case result do
            {:ok, _} -> :ok
            {:crash, _} ->
              flunk("ExPdfium.open_blob crashed on #{unquote(fname)}: #{inspect(result)}")
          end
        end
      end
    end
  end

  describe "Image.OCR (Tesseract) crash-fuzz" do
    for path <- @all_fixtures do
      fname = Path.basename(path)
      size = File.stat!(path).size
      skip_big = size > 50 * @mb

      if skip_big do
        @tag :skip
        test "Tesseract does not crash on #{fname}" do
          {:ok, _bytes} = File.read(unquote(path))
        end
      else
        test "Tesseract does not crash on #{fname}" do
          {:ok, bytes} = File.read(unquote(path))

          result =
            try do
              case Image.OCR.new(locale: "eng") do
                {:ok, instance} ->
                  case Image.OCR.recognize(instance, bytes) do
                    {:ok, _words} -> {:ok, :recognized}
                    {:error, reason} -> {:ok, {:error, reason}}
                  end

                {:error, reason} ->
                  {:ok, {:error, reason}}
              end
            rescue
              e -> {:crash, Exception.message(e)}
            catch
              :exit, reason -> {:crash, {:exit, reason}}
            end

          case result do
            {:ok, _} -> :ok
            {:crash, _} ->
              flunk("Image.OCR crashed on #{unquote(fname)}: #{inspect(result)}")
          end
        end
      end
    end
  end

  describe "Vix.Vips.Image.new_from_buffer crash-fuzz" do
    for path <- @all_fixtures do
      fname = Path.basename(path)
      size = File.stat!(path).size
      skip_big = size > 50 * @mb

      if skip_big do
        @tag :skip
        test "libvips does not crash on #{fname}" do
          {:ok, _bytes} = File.read(unquote(path))
        end
      else
        test "libvips does not crash on #{fname}" do
          {:ok, bytes} = File.read(unquote(path))

          result =
            try do
              case Vix.Vips.Image.new_from_buffer(bytes) do
                {:ok, img} ->
                  _ = Vix.Vips.Image.width(img)
                  {:ok, :loaded}

                {:error, reason} ->
                  {:ok, {:error, reason}}
              end
            rescue
              e -> {:crash, Exception.message(e)}
            catch
              :exit, reason -> {:crash, {:exit, reason}}
            end

          case result do
            {:ok, _} -> :ok
            {:crash, _} ->
              flunk("libvips crashed on #{unquote(fname)}: #{inspect(result)}")
          end
        end
      end
    end
  end
end
