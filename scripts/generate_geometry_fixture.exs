# Generate 1000 random CSS→PDF tuples using the Elixir geometry module
# and write them as a JSON fixture for the Playwright differential test.
#
# Usage: mix run scripts/generate_geometry_fixture.exs
# Output: test/fixtures/geometry_differential_fixture.json

Code.ensure_loaded!(Quire.Geometry)
alias Quire.Geometry

# Seeded RNG for deterministic output
:rand.seed(:exrop, {1, 42, 3})

rand_float = fn ->
  :rand.uniform()
end

rand_int = fn min, max ->
  min + floor(rand_float.() * (max - min + 1))
end

tuples =
  Enum.map(1..1000, fn _ ->
    pw = rand_int.(100, 1200)
    ph = rand_int.(100, 1600)
    x = rand_int.(0, max(0, pw - 10))
    y = rand_int.(0, max(0, ph - 10))
    bw = rand_int.(10, max(10, pw - x))
    bh = rand_int.(10, max(10, ph - y))
    rot = Enum.random([0, 90, 180, 270])

    {px, py, p_w, p_h} = Geometry.css_to_pdf(x, y, bw, bh, pw, ph, rot)
    ok = Geometry.round_trip_ok?(x, y, bw, bh, pw, ph, rot)

    %{
      pw: pw,
      ph: ph,
      css_x: x,
      css_y: y,
      css_w: bw,
      css_h: bh,
      rot: rot,
      pdf_x: px,
      pdf_y: py,
      pdf_w: p_w,
      pdf_h: p_h,
      round_trip_ok: ok
    }
  end)

fixture_path = Path.expand("../test/fixtures/geometry_differential_fixture.json", __DIR__)
fixture_dir = Path.dirname(fixture_path)
File.mkdir_p!(fixture_dir)
File.write!(fixture_path, Jason.encode!(%{tuples: tuples, generated_at: DateTime.utc_now(), count: 1000}))
IO.puts("Generated #{length(tuples)} tuples → #{fixture_path}")
