defmodule Quire.MixProject do
  use Mix.Project

  def project do
    [
      app: :quire,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Quire.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  # Versions verified against Hex on 2026-07-29 with `mise exec -- mix hex.info`.
  # Where Appendix A disagrees with the registry, the registry wins and the
  # amendment is recorded in T-003 (pdf-86r).
  defp deps do
    [
      # --- Phoenix / web ------------------------------------------------------
      {:phoenix, "~> 1.8.9"},
      {:phoenix_html, "~> 4.3"},
      # Floor is 1.2.7 per §3.1. Do not relax it.
      {:phoenix_live_view, "~> 1.2.7"},
      {:phoenix_live_dashboard, "~> 0.8.7"},
      {:bandit, "~> 1.12"},
      {:dns_cluster, "~> 0.2.0"},

      # --- Database -----------------------------------------------------------
      # `ecto` is declared explicitly for UUID v7 (§3.7). Generation
      # (`autogenerate: [version: 7]`, `precision: :monotonic`) landed in
      # 3.14.0, but the helpers `to_datetime/1`, `to_unix/2` and `version/1`
      # landed in 3.14.1 — so the floor is .1, not .0. `ecto_sql ~> 3.13` alone
      # would admit a version that cannot do this and silently break the T-200
      # schemas. See pdf-qy6h.
      {:ecto, "~> 3.14.1"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:phoenix_ecto, "~> 4.7"},

      # --- Auth (phx.gen.auth, T-200) -----------------------------------------
      {:bcrypt_elixir, "~> 3.3"},

      # --- Assets -------------------------------------------------------------
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      # Appendix A lists daisyUI under "Deliberately absent". T-025 owns deleting
      # the dep, the `@plugin` blocks in assets/css/app.css and every
      # daisyUI-classed element in one pass. It stays until then; MIT, so it is
      # not an Appendix E problem while it lingers.
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},

      # --- Platform -----------------------------------------------------------
      {:swoosh, "~> 1.26"},
      # req 0.7.0 carried breaking changes (`current_request_steps` removed,
      # `run_finch` -> `Req.Finch`, `put_plug`/`run_plug` -> `Req.Plug`). Pin to
      # the 0.7.1 line the lock actually holds — `~> 0.7` would mandate 0.7.0 as
      # its floor and still float to 0.9.x, which is not a bound at all.
      {:req, "~> 0.7.1"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.3"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.4"},

      # --- Jobs (§7.5) --------------------------------------------------------
      {:oban, "~> 2.23"},

      # --- PDF engine (§3.3, §7.3) --------------------------------------------
      # Exact pin per §7.3: `== 0.5.1`, never `~> 0.5.1`.
      {:ex_pdfium, "== 0.5.1"},
      # Not in Appendix A, but it is ex_pdfium's only non-optional Hex dependency
      # and the component that performs the aarch64-apple-darwin download. It
      # asks for `~> 0.8`, which floats to 0.9.0 — a line it was not developed
      # against (0.9.0 changed the download path). Hold the 0.8 line.
      {:rustler_precompiled, "~> 0.8.4"},
      # Build-time only: needed if a precompiled artefact is ever missing
      # (`EXPDFIUM_BUILD=1`), and later for Tauri (§12). Not on the happy path.
      # NB §3.1 also justifies rustler with "the Tesseract NIF" — void, see OCR.
      {:rustler, "~> 0.38", runtime: false},

      # --- Imaging (§3.3) -----------------------------------------------------
      # Appendix A assigns this pin to T-019; T-003 takes it because nothing
      # about either package is still open. vix is pinned exactly because its
      # precompiled artefact carries a bundled libvips (8.18.3 in 0.40.0), so a
      # minor bump swaps a native library — the same reasoning §7.3 applies to
      # ex_pdfium. `image` is pinned to the same granularity deliberately: it is
      # vix's principal consumer, and letting it float means a future image
      # release that raises its vix floor makes the pair hard-unsatisfiable.
      {:vix, "== 0.40.0"},
      {:image, "~> 0.72.0"},

      # --- OCR (§3.3) — NOT PINNED, owner T-019 (pdf-9qh) ---------------------
      # `tesseract_elixir` DOES NOT EXIST on Hex and never has. Appendix A and
      # Appendix D name a package that was never published; those rows must be
      # deleted, not corrected. The only in-process Tesseract NIF on Hex that
      # reports per-word confidence (§9.1) is `image_ocr` 0.2.0, Apache-2.0 —
      # verified working end to end, but it ships no precompiled artefact and
      # links against Homebrew tesseract/leptonica, which is exactly the
      # vendored-vs-Homebrew question the T-019 ADR owes. Uncomment once it
      # lands. See pdf-tuj.
      #
      # {:image_ocr, "== 0.2.0"},
      #
      # DO NOT substitute `tesseract_ocr` — it is the highest-download
      # "tesseract" package on Hex and it shells out via
      # `System.cmd("tesseract", ...)`, which §3.4 forbids outright.

      # --- Documents ----------------------------------------------------------
      # Appendix A says `~> 1.x`, which is not valid Mix requirement syntax.
      {:saxy, "~> 1.6"},
      # Appendix A marks this a MAY; T-074 may replace it with a native writer.
      {:elixlsx, "~> 0.6"},
      # Only the print_to_pdf path may be used. Its PDF/A path shells out to
      # Ghostscript (AGPL-3.0), which §3.4 forbids; PDF/A is Quire.PdfA (T-084).
      {:chromic_pdf, "== 1.17.1"},

      # --- Security -----------------------------------------------------------
      {:cloak_ecto, "~> 1.3"},
      # `uniq` is deliberately absent (pdf-qy6h): ecto 3.14.1 supplies UUID v7
      # generation, timestamp extraction and a monotonic precision mode that
      # uniq does not have at all.

      # --- Dev / test ---------------------------------------------------------
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_test, "~> 0.11.1", only: :test, runtime: false},
      {:lazy_html, "~> 0.1.12", only: :test},
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      {:benchee, "~> 1.5", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind quire", "esbuild quire"],
      "assets.deploy": [
        "tailwind quire --minify",
        "esbuild quire --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
