defmodule LeiService.RepoTopologyTest do
  @moduledoc """
  The test databases are laid out the way production's are.

  `Lei.Repo` holds the ledger and `LeiService.Repo` is Oban's. In production
  both are configured from one `DATABASE_URL`: one database, two connection
  pools, one `schema_migrations` table shared by two migration directories.

  In test they addressed two different databases, so CI could not see anything
  that arises from sharing one -- a version collision between the two
  directories, or a migration that assumes a table the other repo created.
  `docs/PRODUCTION_READINESS.md` records the shared `schema_migrations` as a
  known consequence of the production layout; nothing exercised it.

  Two pools on one database is not the same as one pool. A write through
  `Lei.Repo` is still invisible to a `LeiService.Repo` transaction, in test and
  in production alike -- which is why #217's charge-and-enqueue cannot be one
  transaction. Matching the layout does not change that; it stops the test
  environment from being a third arrangement that is neither.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../../config", __DIR__)

  defp config_for(env, vars) do
    saved = for {k, _} <- vars, into: %{}, do: {k, System.get_env(k)}
    for {k, v} <- vars, do: System.put_env(k, v)

    try do
      compile = Config.Reader.read!(Path.join(@root, "config.exs"), env: env, target: :host)

      merged =
        case env do
          :test ->
            compile

          _ ->
            Config.Reader.merge(
              compile,
              Config.Reader.read!(Path.join(@root, "runtime.exs"), env: env, target: :host)
            )
        end

      merged[:lei_service]
    after
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end
  end

  test "in test, both repos address one database" do
    assert Application.get_env(:lei_service, Lei.Repo)[:database] ==
             Application.get_env(:lei_service, LeiService.Repo)[:database],
           "the two repos use different test databases, so CI cannot see anything " <>
             "that comes of sharing one -- which is what production does"
  end

  test "in production, both repos are configured from one DATABASE_URL" do
    config =
      config_for(:prod, %{
        "DATABASE_URL" => "ecto://u:p@localhost/shared",
        "LEI_JWT_SECRET" => "topology-test",
        "LEI_SESSION_SECRET" => String.duplicate("s", 88),
        "STRIPE_SECRET_KEY" => "sk_test_" <> String.duplicate("x", 24)
      })

    assert config[Lei.Repo][:url] == config[LeiService.Repo][:url]
    assert config[Lei.Repo][:url] == "ecto://u:p@localhost/shared"
  end

  # The reason the layout matters: one database means one schema_migrations,
  # so a version used by both directories would be recorded once and the second
  # migration silently skipped.
  test "the two migration directories share no version number" do
    versions = fn dir ->
      Path.wildcard(Path.join([__DIR__, "../../priv", dir, "migrations", "*.exs"]))
      |> Enum.map(&(Path.basename(&1) |> String.split("_") |> hd()))
    end

    service = versions.("repo")
    lei = versions.("lei_repo")

    assert service != [], "no LeiService.Repo migrations found; this test checked nothing"
    assert lei != [], "no Lei.Repo migrations found; this test checked nothing"

    assert MapSet.disjoint?(MapSet.new(service), MapSet.new(lei)),
           "the directories share a version number, so one migration would be " <>
             "recorded by the other and never run: " <>
             inspect(MapSet.intersection(MapSet.new(service), MapSet.new(lei)))
  end
end
