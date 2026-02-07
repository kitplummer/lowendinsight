# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Repo do
  use Ecto.Repo,
    otp_app: :lowendinsight,
    adapter: Ecto.Adapters.SQLite3
end
