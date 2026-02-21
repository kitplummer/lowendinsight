# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Cache.OCITest do
  use ExUnit.Case, async: true

  alias Lei.Cache.OCI

  describe "blob_descriptor/2" do
    test "computes correct sha256 digest and size" do
      data = "hello world"
      media_type = "application/octet-stream"

      desc = OCI.blob_descriptor(data, media_type)

      expected_digest =
        "sha256:" <> (:crypto.hash(:sha256, data) |> Base.encode16(case: :lower))

      assert desc.digest == expected_digest
      assert desc.size == byte_size(data)
      assert desc.mediaType == media_type
      assert desc.data == data
    end

    test "different data produces different digests" do
      d1 = OCI.blob_descriptor("foo", "text/plain")
      d2 = OCI.blob_descriptor("bar", "text/plain")

      assert d1.digest != d2.digest
    end
  end

  describe "build_manifest/2" do
    test "returns well-formed OCI manifest" do
      config = %{mediaType: "application/vnd.lei.cache.config.v1+json", digest: "sha256:abc", size: 10}

      layers = [
        %{mediaType: "application/vnd.lei.cache.manifest+json", digest: "sha256:def", size: 20},
        %{mediaType: "application/vnd.lei.cache.jsonl+gzip", digest: "sha256:ghi", size: 30}
      ]

      manifest = OCI.build_manifest(config, layers)

      assert manifest.schemaVersion == 2
      assert manifest.mediaType == "application/vnd.oci.image.manifest.v1+json"
      assert manifest.config == config
      assert manifest.layers == layers
      assert manifest.annotations["org.opencontainers.image.title"] == "lei-cache"
      assert manifest.annotations["org.opencontainers.image.vendor"] == "Kit Plummer"
    end
  end

  describe "package/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "lei-oci-test-#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, dir: dir}
    end

    test "packages cache files into OCI artifact", %{dir: dir} do
      manifest = %{"format_version" => "1.0", "entry_count" => 1, "date" => "2026-02-05"}
      File.write!(Path.join(dir, "manifest.json"), Poison.encode!(manifest))

      jsonl = ~s({"header":{},"data":{"repo":"https://example.com/repo"}}\n)
      File.write!(Path.join(dir, "cache.jsonl.gz"), :zlib.gzip(jsonl))

      {:ok, oci_manifest_json, blobs} = OCI.package(dir)

      oci_manifest = Poison.decode!(oci_manifest_json)

      assert oci_manifest["schemaVersion"] == 2
      assert length(oci_manifest["layers"]) == 2
      assert length(blobs) == 3

      media_types = Enum.map(oci_manifest["layers"], & &1["mediaType"])
      assert "application/vnd.lei.cache.manifest+json" in media_types
      assert "application/vnd.lei.cache.jsonl+gzip" in media_types

      # Verify blobs have matching digests
      blob_digests = Enum.map(blobs, fn {digest, _data} -> digest end)
      manifest_digests = Enum.map(oci_manifest["layers"], & &1["digest"])
      config_digest = oci_manifest["config"]["digest"]

      assert config_digest in blob_digests
      Enum.each(manifest_digests, fn d -> assert d in blob_digests end)
    end

    test "returns error for missing files", %{dir: dir} do
      assert {:error, _} = OCI.package(dir)
    end

    test "packages with invalid manifest JSON uses fallback config", %{dir: dir} do
      File.write!(Path.join(dir, "manifest.json"), "not-valid-json{{{")
      jsonl = ~s({"repo":"test"}\n)
      File.write!(Path.join(dir, "cache.jsonl.gz"), :zlib.gzip(jsonl))

      {:ok, oci_manifest_json, blobs} = OCI.package(dir)
      oci_manifest = Poison.decode!(oci_manifest_json)

      # build_config falls back to %{} when manifest JSON is invalid
      assert oci_manifest["schemaVersion"] == 2
      assert length(blobs) == 3
    end
  end

  describe "unpack/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "lei-oci-unpack-#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, dir: dir}
    end

    test "unpacks manifest layers to target directory", %{dir: dir} do
      manifest_data = ~s({"format_version":"1.0"})
      jsonl_data = :zlib.gzip(~s({"repo":"test"}\n))

      manifest = %{
        "layers" => [
          %{"mediaType" => OCI.cache_manifest_media_type(), "digest" => "sha256:aaa", "size" => 10},
          %{"mediaType" => OCI.cache_jsonl_media_type(), "digest" => "sha256:bbb", "size" => 20}
        ]
      }

      fetch_fn = fn
        "sha256:aaa" -> {:ok, manifest_data}
        "sha256:bbb" -> {:ok, jsonl_data}
      end

      assert :ok = OCI.unpack(manifest, dir, fetch_fn)
      assert File.exists?(Path.join(dir, "manifest.json"))
      assert File.exists?(Path.join(dir, "cache.jsonl.gz"))
    end

    test "returns error when blob fetch fails", %{dir: dir} do
      manifest = %{
        "layers" => [
          %{"mediaType" => OCI.cache_manifest_media_type(), "digest" => "sha256:aaa", "size" => 10}
        ]
      }

      fetch_fn = fn _ -> {:error, "not found"} end

      assert {:error, _} = OCI.unpack(manifest, dir, fetch_fn)
    end
  end

  describe "media_type_to_filename/1" do
    test "maps known media types" do
      assert OCI.media_type_to_filename(OCI.cache_manifest_media_type()) == "manifest.json"
      assert OCI.media_type_to_filename(OCI.cache_jsonl_media_type()) == "cache.jsonl.gz"
    end

    test "returns unknown for unrecognized types" do
      assert OCI.media_type_to_filename("application/octet-stream") == "unknown"
    end
  end
end
