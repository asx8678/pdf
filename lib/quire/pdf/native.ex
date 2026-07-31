defmodule Quire.Pdf.Native do
  @moduledoc false

  # Built from source, every time, by `use Rustler` — there is no precompiled
  # artefact for this crate the way there is for ex_pdfium. That means a Rust
  # toolchain is a hard build requirement for the project (mise.toml pins it),
  # which is a property T-003 had otherwise avoided. See pdf-ysy3.
  #
  # `:rustler` is declared `runtime: false` in mix.exs and that is CORRECT: the
  # generated `rustler_init/0` (deps/rustler/lib/rustler.ex:148-168) calls only
  # `:code.purge/1`, `Application.app_dir/2` and `:erlang.load_nif/2`. Nothing
  # in the `Rustler` namespace is touched after compilation, so the dependency
  # never needs to be started or shipped in a release.
  #
  # Note there is no `rustler_crates:` key in mix.exs and no `:rustler` entry in
  # `compilers:`. Both were removed in rustler 0.22; since then `use Rustler`
  # compiles the crate itself during this module's compilation, and registers
  # the crate sources as `@external_resource` so a `.rs` edit triggers a
  # rebuild.

  use Rustler, otp_app: :quire, crate: :quire_pdf

  # Keep these stubs in sync with the #[rustler::nif] fns in
  # native/quire_pdf/src/lib.rs. Each raises until the NIF library loads.
  # All 11 are `schedule = "DirtyCpu"` (plan3.md §7.3, T-021).

  def open(_bytes), do: :erlang.nif_error(:nif_not_loaded)
  def open_file(_path), do: :erlang.nif_error(:nif_not_loaded)
  def page_count(_doc), do: :erlang.nif_error(:nif_not_loaded)

  def save(_doc), do: :erlang.nif_error(:nif_not_loaded)

  def save_with(_doc, _use_object_streams, _use_xref_streams),
    do: :erlang.nif_error(:nif_not_loaded)

  def incremental_save(_doc), do: :erlang.nif_error(:nif_not_loaded)

  def outline(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def set_outline(_doc, _entries), do: :erlang.nif_error(:nif_not_loaded)
  def set_outline_relaxed(_doc, _entries), do: :erlang.nif_error(:nif_not_loaded)

  def catalog(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def get_object(_doc, _obj_num, _gen_num), do: :erlang.nif_error(:nif_not_loaded)
  def set_object(_doc, _obj_num, _gen_num, _object), do: :erlang.nif_error(:nif_not_loaded)

  def allocate_object_id(_doc), do: :erlang.nif_error(:nif_not_loaded)
end
