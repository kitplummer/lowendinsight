defmodule Lowendinsight.PackageFilesTest do
  @moduledoc """
  The published package carries its README and LICENCE.

  Both live at the repository root, and hex refuses a path outside the app
  ("unsafe path in tarball"), so the library keeps copies. Copies drift, so
  this fails when they do.
  """
  use ExUnit.Case, async: true

  @app Path.expand("../", __DIR__)
  @root Path.expand("../../../", __DIR__)

  for file <- ["README.md", "LICENSE"] do
    test "#{file} is in the package and matches the repository root" do
      app_copy = Path.join(@app, unquote(file))
      root_copy = Path.join(@root, unquote(file))

      assert File.exists?(app_copy),
             "#{unquote(file)} is missing from apps/lowendinsight, so the Hex package ships without it"

      assert File.read!(app_copy) == File.read!(root_copy),
             "apps/lowendinsight/#{unquote(file)} has drifted from the root copy; " <>
               "copy the root file over it"
    end
  end

  test "hex's default file list picks them up" do
    # No :files override in package/0 -- hex's defaults include README*,
    # LICENSE* and CHANGELOG* from the app directory. An override that forgot
    # one would ship a package without it.
    refute File.read!(Path.join(@app, "mix.exs")) =~ "files:"
  end
end
