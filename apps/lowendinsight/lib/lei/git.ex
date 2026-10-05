defmodule Lei.Git do
  @moduledoc """
  Runs git, without a dependency that has not been touched in seven years (#250).

  `git_cli` is 136 lines wrapping `System.cmd`, and its one notable decision --
  `stderr_to_stdout: true` -- is why `GitModule.git_log_split/2` existed: git's
  `warning:` lines are on stderr, where they belong, and the wrapper mixed them
  into the output we then parsed around. Keeping the streams apart removes the
  problem rather than filtering it.

  There was no library to move to. Measured with our own analyzer, every Elixir
  git binding is abandoned: `xgit` 6.5 years with one functional contributor,
  `gitex` 4.9, `geef` 9.9 with one. Swapping would have traded a dead
  dependency for a deader one.

  ## Failure is never silence

  `System.cmd/3` returns `{output, status}`, so the tempting shape is:

      {out, _} = System.cmd("git", args)

  which turns a failed command into empty output, and empty output into an
  analysis that examined nothing and reported `low`. That is the defect this
  codebase produces most often, so `run!/2` raises and is the default; `run/2`
  exists for the callers that genuinely handle a non-zero status, and makes
  them say so.

  ## The environment

  Git is asked not to be interactive. Without `GIT_TERMINAL_PROMPT=0` a clone
  of a private or renamed repository waits for credentials rather than failing,
  which presents as a hang rather than an error and is a plausible cause of
  analyses that time out. Neither we nor `git_cli` set it before.
  """

  defmodule Repository do
    @moduledoc "A cloned repository on disk."
    @enforce_keys [:path]
    defstruct [:path]
    @type t :: %__MODULE__{path: String.t()}
  end

  defmodule Error do
    @moduledoc "A git command that exited non-zero."
    defexception [:message, :status, :args]
  end

  # Empty rather than absent for GIT_ASKPASS: an unset variable lets git fall
  # back to a configured helper, which is the interactive path being closed.
  @env [
    {"GIT_TERMINAL_PROMPT", "0"},
    {"GIT_ASKPASS", ""},
    {"GCM_INTERACTIVE", "never"}
  ]

  @doc "The environment every git command runs under."
  @spec env() :: [{String.t(), String.t()}]
  def env, do: @env

  @doc "A handle on an existing repository directory. Does no work."
  @spec new(String.t()) :: Repository.t()
  def new(path), do: %Repository{path: path}

  @doc """
  Runs git, returning `{:ok, stdout}` or `{:error, status, stdout}`.

  stderr is left on the parent's stream rather than captured, so nothing git
  says about itself can be parsed as output. In normal operation it says
  nothing: `git log --name-only` writes zero bytes there, and `clone` is passed
  `--quiet`.
  """
  @spec run(Repository.t() | nil, [String.t()], keyword) ::
          {:ok, String.t()} | {:error, non_neg_integer, String.t()}
  def run(repo, args, opts \\ []) when is_list(args) do
    # Capturing folds stderr into the returned text, so it is used only where
    # git's own words must not reach the console -- see `clone/2`. Everywhere
    # else the streams stay apart, which is the point of not using `git_cli`.
    capture = Keyword.get(opts, :capture_stderr, false)

    cmd_opts =
      case repo do
        %Repository{path: path} -> [env: @env, cd: path, stderr_to_stdout: capture]
        nil -> [env: @env, stderr_to_stdout: capture]
      end

    case System.cmd("git", args, cmd_opts) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, status, out}
    end
  end

  @doc """
  Runs git, returning stdout, and raises `Lei.Git.Error` on a non-zero exit.

  The default. A caller that wants to proceed without the answer has to say so
  by using `run/2`, rather than getting an empty string and not noticing.
  """
  @spec run!(Repository.t() | nil, [String.t()], keyword) :: String.t()
  def run!(repo, args, opts \\ []) do
    case run(repo, args, opts) do
      {:ok, out} ->
        out

      {:error, status, _out} ->
        raise Error,
          message: "git #{Enum.join(args, " ")} exited #{status}",
          status: status,
          args: args
    end
  end

  @doc """
  Clones into `path`.

  `--quiet` because clone writes its progress, including the destination, to
  stderr, and this process does not need it on the console. `--` because a URL
  is data: `RemoteUrl.validate/1` already requires https so one cannot begin
  with a dash, and the separator costs nothing to keep it that way.

  This is the one command whose stderr is captured. Clone is also the only one
  that names the remote, and a failure prints `fatal: repository '<url>' does
  not exist`. Left on the parent's stream that line reaches production logs,
  where a repository URL sits beside a ledger timestamp and puts a paying
  wallet next to what it analysed (#149). Capturing costs nothing here because
  a successful quiet clone writes nothing to stdout either way, and the text is
  discarded rather than returned.
  """
  @spec clone(String.t(), String.t()) :: {:ok, Repository.t()} | {:error, non_neg_integer}
  def clone(url, path) do
    case run(nil, ["clone", "--quiet", "--", url, path], capture_stderr: true) do
      {:ok, _} -> {:ok, %Repository{path: path}}
      {:error, status, _} -> {:error, status}
    end
  end
end
