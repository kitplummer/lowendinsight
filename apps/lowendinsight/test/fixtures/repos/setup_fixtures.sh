#!/bin/bash
# Script to create deterministic test fixture repositories
# Run from the test/fixtures/repos directory

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Helper to create commits with fixed dates
git_commit() {
    local message="$1"
    local date="$2"
    local author_name="${3:-Test Author}"
    local author_email="${4:-test@example.com}"

    GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
    GIT_AUTHOR_NAME="$author_name" GIT_AUTHOR_EMAIL="$author_email" \
    GIT_COMMITTER_NAME="$author_name" GIT_COMMITTER_EMAIL="$author_email" \
    git commit -m "$message"
}

echo "Creating simple_repo..."
rm -rf simple_repo
mkdir simple_repo && cd simple_repo
git init --initial-branch=main
git config user.email "test@example.com"
git config user.name "Test Author"

# First commit
echo "# Simple Test Repo" > README.md
git add README.md
git_commit "Initial commit" "2024-01-01T10:00:00" "Test Author" "test@example.com"

# Second commit
echo "def hello, do: :world" > lib.ex
git add lib.ex
git_commit "Add library file" "2024-01-15T14:30:00" "Test Author" "test@example.com"

# Third commit
echo "Test content" > test.txt
git add test.txt
git_commit "Add test file" "2024-02-01T09:00:00" "Test Author" "test@example.com"

cd ..

echo "Creating multi_contributor_repo..."
rm -rf multi_contributor_repo
mkdir multi_contributor_repo && cd multi_contributor_repo
git init --initial-branch=main
git config user.email "alice@example.com"
git config user.name "Alice Developer"

# Alice's commits
echo "# Multi Contributor Repo" > README.md
git add README.md
git_commit "Initial commit by Alice" "2024-01-01T10:00:00" "Alice Developer" "alice@example.com"

echo "defmodule App do\nend" > app.ex
git add app.ex
git_commit "Add main app module" "2024-01-10T11:00:00" "Alice Developer" "alice@example.com"

# Bob's commits
echo "defmodule Helper do\nend" > helper.ex
git add helper.ex
git_commit "Add helper module" "2024-01-20T15:00:00" "Bob Coder" "bob@example.com"

echo "# Tests go here" > test.md
git add test.md
git_commit "Add test documentation" "2024-01-25T16:00:00" "Bob Coder" "bob@example.com"

# Carol's commit
echo "config = []" > config.exs
git add config.exs
git_commit "Add config file" "2024-02-01T09:00:00" "Carol Engineer" "carol@example.com"

# Alice again
echo "defmodule App do\n  def run, do: :ok\nend" > app.ex
git add app.ex
git_commit "Implement run function" "2024-02-10T10:00:00" "Alice Developer" "alice@example.com"

cd ..

echo "Creating single_commit_repo..."
rm -rf single_commit_repo
mkdir single_commit_repo && cd single_commit_repo
git init --initial-branch=main
git config user.email "solo@example.com"
git config user.name "Solo Committer"

echo "# Single Commit Repo" > README.md
git add README.md
git_commit "Initial and only commit" "2024-01-15T12:00:00" "Solo Committer" "solo@example.com"

cd ..

echo "Creating elixir_project_repo..."
rm -rf elixir_project_repo
mkdir elixir_project_repo && cd elixir_project_repo
git init --initial-branch=main
git config user.email "dev@example.com"
git config user.name "Elixir Dev"

# Create typical Elixir project structure
mkdir -p lib test config

cat > mix.exs << 'MIXFILE'
defmodule TestProject.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_project,
      version: "0.1.0",
      elixir: "~> 1.14",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:poison, "~> 5.0"}
    ]
  end
end
MIXFILE

cat > mix.lock << 'LOCKFILE'
%{
  "poison": {:hex, :poison, "5.0.0", "fake_hash", [:mix], [], "hexpm", "fake_checksum"},
}
LOCKFILE

echo "defmodule TestProject do\nend" > lib/test_project.ex
echo "use Mix.Config" > config/config.exs
echo "ExUnit.start()" > test/test_helper.exs

git add .
git_commit "Initial Elixir project" "2024-01-01T10:00:00" "Elixir Dev" "dev@example.com"

cd ..

echo "Creating node_project_repo..."
rm -rf node_project_repo
mkdir node_project_repo && cd node_project_repo
git init --initial-branch=main
git config user.email "node@example.com"
git config user.name "Node Dev"

cat > package.json << 'PKGJSON'
{
  "name": "test-project",
  "version": "1.0.0",
  "dependencies": {
    "lodash": "^4.17.21"
  }
}
PKGJSON

echo "console.log('hello');" > index.js

git add .
git_commit "Initial Node project" "2024-01-01T10:00:00" "Node Dev" "node@example.com"

cd ..

echo "Creating python_project_repo..."
rm -rf python_project_repo
mkdir python_project_repo && cd python_project_repo
git init --initial-branch=main
git config user.email "python@example.com"
git config user.name "Python Dev"

cat > requirements.txt << 'REQS'
requests==2.28.0
flask==2.0.0
REQS

echo "print('hello')" > main.py

git add .
git_commit "Initial Python project" "2024-01-01T10:00:00" "Python Dev" "python@example.com"

cd ..

echo "All fixture repositories created successfully!"
