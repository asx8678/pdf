%{
  configs: [
    %{
      name: "default",
      files: %{include: ["lib/", "test/"], exclude: ["deps/", "_build/"]},
      checks: [
        {Quire.Checks.NoFileOps, []}
      ]
    }
  ]
}
