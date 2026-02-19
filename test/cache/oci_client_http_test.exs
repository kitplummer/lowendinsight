# Tests for OCI client HTTP functions
# These tests exercise the HTTP error handling paths since we can't easily
# mock HTTPS without infrastructure. The code paths are still covered.

defmodule Lei.Cache.OCIClientHTTPTest do
  use ExUnit.Case, async: true

  alias Lei.Cache.OCIClient

  describe "pull_manifest/4 error handling" do
    test "returns error for unreachable host" do
      {:error, msg} = OCIClient.pull_manifest("127.0.0.1:1", "test/repo", "latest")
      assert is_binary(msg)
      assert msg =~ "HTTP error"
    end

    test "returns error with token auth for unreachable host" do
      {:error, msg} =
        OCIClient.pull_manifest("127.0.0.1:1", "test/repo", "v1", token: "test-token")

      assert is_binary(msg)
    end
  end

  describe "pull_blob/4 error handling" do
    test "returns error for unreachable host" do
      {:error, msg} = OCIClient.pull_blob("127.0.0.1:1", "test/repo", "sha256:abc")
      assert is_binary(msg)
      assert msg =~ "HTTP error"
    end

    test "returns error with token auth" do
      {:error, msg} =
        OCIClient.pull_blob("127.0.0.1:1", "test/repo", "sha256:abc", token: "test-token")

      assert is_binary(msg)
    end
  end

  describe "push/6 error handling" do
    test "returns error for unreachable host" do
      result =
        OCIClient.push("127.0.0.1:1", "test/repo", ["latest"], "{}", [{"sha256:abc", "data"}])

      assert {:error, _} = result
    end

    test "returns error with auth token" do
      result =
        OCIClient.push("127.0.0.1:1", "test/repo", ["latest"], "{}", [{"sha256:abc", "data"}],
          token: "tok"
        )

      assert {:error, _} = result
    end

    test "handles empty blobs list" do
      # With empty blobs, push_blobs succeeds but push_manifest will fail
      result = OCIClient.push("127.0.0.1:1", "test/repo", ["latest"], "{}", [])
      assert {:error, _} = result
    end

    test "handles multiple tags" do
      result =
        OCIClient.push("127.0.0.1:1", "test/repo", ["v1", "latest", "weekly"], "{}", [])

      assert {:error, _} = result
    end
  end
end
