# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule TimeHelperTest do
  use ExUnit.Case, async: true
  doctest TimeHelper

  describe "sec_to_str/1" do
    test "converts seconds to full breakdown string" do
      string = TimeHelper.sec_to_str(11_223_344)
      assert "18 wk, 3 d, 21 hr, 35 min, 44 sec" == string
    end

    test "handles zero seconds" do
      assert "" == TimeHelper.sec_to_str(0)
    end

    test "handles only seconds" do
      assert "45 sec" == TimeHelper.sec_to_str(45)
    end

    test "handles only minutes" do
      assert "5 min" == TimeHelper.sec_to_str(300)
    end

    test "handles hours and minutes" do
      # 1 hour, 26 min, 51 sec
      assert "1 hr, 26 min, 51 sec" == TimeHelper.sec_to_str(5211)
    end

    test "handles days" do
      # 2 days = 172800 seconds
      assert "2 d" == TimeHelper.sec_to_str(172_800)
    end

    test "handles weeks" do
      # 1 week = 604800 seconds
      assert "1 wk" == TimeHelper.sec_to_str(604_800)
    end
  end

  describe "sec_to_weeks/1" do
    test "converts seconds to weeks" do
      assert TimeHelper.sec_to_weeks(333_282_014) == 551
    end

    test "returns 0 for less than a week" do
      assert TimeHelper.sec_to_weeks(604_799) == 0
    end

    test "returns 1 for exactly one week" do
      assert TimeHelper.sec_to_weeks(604_800) == 1
    end
  end

  describe "sec_to_days/1" do
    test "converts seconds to days" do
      assert TimeHelper.sec_to_days(333_282_014) == 3857
    end

    test "returns 0 for less than a day" do
      assert TimeHelper.sec_to_days(86_399) == 0
    end

    test "returns 1 for exactly one day" do
      assert TimeHelper.sec_to_days(86_400) == 1
    end
  end

  describe "get_commit_delta/1" do
    test "computes delta for old date" do
      seconds = TimeHelper.get_commit_delta("2009-01-07T03:23:20Z")
      weeks = TimeHelper.sec_to_weeks(seconds)
      assert weeks > 550
    end

    test "computes delta for recent date" do
      seconds = TimeHelper.get_commit_delta("2019-01-07T03:23:20Z")
      weeks = TimeHelper.sec_to_weeks(seconds)
      assert weeks >= 30
    end

    test "returns error for invalid date format" do
      result = TimeHelper.get_commit_delta("not-a-date")
      assert {:error, _} = result
    end

    test "handles date without timezone" do
      result = TimeHelper.get_commit_delta("2023-01-01")
      assert {:error, _} = result
    end
  end

  describe "sum_ts_diff/1" do
    test "returns 0 for single element list" do
      # With single element, no difference to calculate
      list = [[:commit1 | 1000]]
      assert {:ok, 0} = TimeHelper.sum_ts_diff(list)
    end

    test "computes difference for two element list" do
      list = [[:commit1 | 1000], [:commit2 | 2000]]
      assert {:ok, 1000} = TimeHelper.sum_ts_diff(list)
    end

    test "computes cumulative difference for three element list" do
      list = [[:c1 | 1000], [:c2 | 2000], [:c3 | 4000]]
      {:ok, result} = TimeHelper.sum_ts_diff(list)
      # (2000-1000) + (4000-2000) = 1000 + 2000 = 3000
      assert result == 3000
    end
  end

  describe "get_commit_delta/1 additional cases" do
    test "computes delta for very recent date" do
      # Just a few seconds ago
      recent = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()
      seconds = TimeHelper.get_commit_delta(recent)
      assert is_integer(seconds)
      assert seconds >= 59
      assert seconds < 120
    end
  end

  describe "sec_to_str/1 additional cases" do
    test "handles large values with all units" do
      # 2 weeks + 3 days + 4 hours + 5 minutes + 6 seconds
      seconds = 2 * 604_800 + 3 * 86_400 + 4 * 3_600 + 5 * 60 + 6
      result = TimeHelper.sec_to_str(seconds)
      assert result =~ "2 wk"
      assert result =~ "3 d"
      assert result =~ "4 hr"
      assert result =~ "5 min"
      assert result =~ "6 sec"
    end
  end

  describe "sec_to_days/1 additional" do
    test "handles zero" do
      assert TimeHelper.sec_to_days(0) == 0
    end
  end

  describe "sec_to_weeks/1 additional" do
    test "handles zero" do
      assert TimeHelper.sec_to_weeks(0) == 0
    end
  end
end
