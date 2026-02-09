# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lowendinsight.HelpersTest do
  use ExUnit.Case, async: true
  doctest Helpers

  test "converter works?" do
    Helpers.convert_config_to_list(Application.get_all_env(:lowendinsight))
    |> Poison.encode!()
  end

  test "validate path url" do
    {:ok, cwd} = File.cwd()
    assert :ok == Helpers.validate_url("file://#{cwd}")
    assert {:error, "invalid URI path"} == Helpers.validate_url("file:///blah")
  end

  test "validate urls" do
    urls = ["https://github.com/kitplummer/gbtestee", "https://github.com/kitplummer/goa"]
    assert :ok == Helpers.validate_urls(urls)
    urls = ["://github.com/kitplummer/cliban"] ++ urls
    assert {:error, %{:message => "invalid URI", :urls => ["://github.com/kitplummer/cliban"]}} == Helpers.validate_urls(urls)
    urls = ["https//github.com/kitplummer/clikan"] ++ urls
    assert {:error, %{:message => "invalid URI", :urls => ["https//github.com/kitplummer/clikan","://github.com/kitplummer/cliban"]}} == Helpers.validate_urls(urls)
  end

  test "validate scheme" do
    assert {:error, "invalid URI scheme"} == Helpers.validate_url("blah://blah")
  end

  test "removes git+ only when it is a prefix in url" do
    assert "https://github.com/hmfng/modal.git" ==
             Helpers.remove_git_prefix("git+https://github.com/hmfng/modal.git")

    assert "git://github.com/hmfng/modal.git" ==
             Helpers.remove_git_prefix("git://github.com/hmfng/modal.git")
  end

  describe "get_slug/1" do
    test "extracts slug from github URL" do
      assert {:ok, "kitplummer/xmpp4rails"} == Helpers.get_slug("https://github.com/kitplummer/xmpp4rails")
    end

    test "handles URL with .git suffix" do
      assert {:ok, "kitplummer/xmpp4rails.git"} == Helpers.get_slug("https://github.com/kitplummer/xmpp4rails.git")
    end

    test "returns error for URL without path" do
      assert {:error, "invalid source URL"} == Helpers.get_slug("https://github.com")
    end
  end

  describe "split_slug/1" do
    test "splits valid slug" do
      assert {:ok, "kitplummer", "xmpp4rails"} == Helpers.split_slug("kitplummer/xmpp4rails")
    end

    test "returns error for slug without slash" do
      assert {:error, "bad_slug"} == Helpers.split_slug("noslash")
    end
  end

  describe "count_forward_slashes/1" do
    test "counts slashes in URL" do
      assert Helpers.count_forward_slashes("https://github.com/test/repo") == 4
    end

    test "returns 0 for string with no slashes" do
      assert Helpers.count_forward_slashes("noslashes") == 0
    end
  end
end
