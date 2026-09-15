defmodule RuntimeSecretsConfigTest do
  @moduledoc """
  Production reads its signing secrets at boot (security, 2026-09-14).

  `config/config.exs` is evaluated when a release is built, where Fly secrets do
  not exist, so production ran with the development defaults for the session
  secret and Lei.Auth's JWT secret regardless of what was set in Fly. These
  evaluate `config/runtime.exs` as production, with controlled environment.
  """
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)
  @session "s" <> String.duplicate("0123456789abcdef", 5)

  @env %{
    "LEI_JWT_SECRET" => "runtime-test-jwt-secret",
    "LEI_SESSION_SECRET" => @session,
    "DATABASE_URL" => "ecto://u:p@localhost/db"
  }

  setup do
    saved = for k <- Map.keys(@env), do: {k, System.get_env(k)}

    on_exit(fn ->
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end)

    :ok
  end

  defp read_prod(env) do
    for {k, v} <- env, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    Config.Reader.read!(@runtime, env: :prod, target: :host)
  end

  test "the session secret and Lei.Auth's JWT secret come from the environment at boot" do
    config = read_prod(@env)

    assert config[:lei_service][:session_secret_key_base] == @session
    assert config[:lei_service][:jwt_secret] == "runtime-test-jwt-secret"
    # One setting for both Lei.Auth and the endpoint's auth plug, and none
    # under the library's namespace (ADR-003).
    refute Keyword.has_key?(config[:lowendinsight] || [], :jwt_secret)
    refute Keyword.has_key?(config[:lowendinsight] || [], :session_secret_key_base)
  end

  test "production refuses to boot without a session secret" do
    assert_raise RuntimeError, ~r/LEI_SESSION_SECRET env var is required/, fn ->
      read_prod(Map.put(@env, "LEI_SESSION_SECRET", nil))
    end
  end

  test "production refuses a short session secret" do
    assert_raise RuntimeError, ~r/at least 64 bytes/, fn ->
      read_prod(Map.put(@env, "LEI_SESSION_SECRET", "too-short"))
    end
  end

  test "production refuses the development default" do
    dev_default =
      "lei_dev_session_secret_that_is_at_least_64_bytes_long_for_cookie_store_to_work_properly"

    assert_raise RuntimeError, ~r/development default/, fn ->
      read_prod(Map.put(@env, "LEI_SESSION_SECRET", dev_default))
    end
  end
end
