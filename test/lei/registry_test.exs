# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.RegistryTest do
  use ExUnit.Case, async: false

  test "create and retrieve a job" do
    dep = %{"ecosystem" => "npm", "package" => "test", "version" => "1.0.0"}
    job_id = Lei.Registry.create_job(dep)

    assert job_id =~ "job-"

    {:ok, job} = Lei.Registry.get_job(job_id)
    assert job.status == :pending
    assert job.dep == dep
    assert is_binary(job.created_at)
  end

  test "update job status" do
    dep = %{"ecosystem" => "npm", "package" => "test", "version" => "1.0.0"}
    job_id = Lei.Registry.create_job(dep)

    :ok = Lei.Registry.update_job(job_id, :running)
    {:ok, job} = Lei.Registry.get_job(job_id)
    assert job.status == :running

    result = %{"risk" => "low"}
    :ok = Lei.Registry.update_job(job_id, :complete, result)
    {:ok, job} = Lei.Registry.get_job(job_id)
    assert job.status == :complete
    assert job.result == result
  end

  test "get_job returns error for unknown job" do
    assert {:error, :not_found} = Lei.Registry.get_job("job-nonexistent")
  end

  test "update_job returns error for unknown job" do
    assert {:error, :not_found} = Lei.Registry.update_job("job-nonexistent", :running)
  end
end
