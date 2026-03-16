#!/bin/sh
# LowEndInsight Docker Entrypoint
# Supports both CLI and programmatic usage for air-gapped environments

set -e

cd /opt/lei

case "$1" in
  analyze)
    # Analyze a single repository (local path or URL)
    shift
    if [ -z "$1" ]; then
      echo "Usage: analyze <repo-path-or-url>"
      exit 1
    fi
    exec mix lei.analyze "$@"
    ;;

  scan)
    # Scan a project's dependencies
    shift
    TARGET="${1:-/workspace}"
    exec mix lei.scan "$TARGET"
    ;;

  bulk)
    # Bulk analyze from a file list
    shift
    if [ -z "$1" ]; then
      echo "Usage: bulk <file-with-repo-list>"
      exit 1
    fi
    exec mix lei.bulk_analyze "$@"
    ;;

  dependencies)
    # List dependencies as JSON
    shift
    TARGET="${1:-/workspace}"
    exec mix lei.dependencies "$TARGET"
    ;;

  sbom)
    # Output container SBOM
    shift
    FORMAT="${1:-cyclonedx}"
    case "$FORMAT" in
      cyclonedx|cdx)
        cat /opt/lei/sbom.cdx.json
        ;;
      spdx)
        cat /opt/lei/sbom.spdx.json
        ;;
      *)
        echo "Unknown format: $FORMAT (use cyclonedx or spdx)"
        exit 1
        ;;
    esac
    ;;

  shell)
    # Interactive Elixir shell
    exec iex -S mix
    ;;

  help|--help|-h)
    cat <<EOF
LowEndInsight (LEI) - OSS Supply Chain Risk Analysis

Usage: docker run lei:<tag> <command> [options]

Commands:
  analyze <repo>      Analyze a git repository (path or URL)
  scan [path]         Scan project dependencies (default: /workspace)
  bulk <file>         Bulk analyze repos listed in file
  dependencies [path] List dependencies as JSON
  sbom [format]       Output container SBOM (cyclonedx or spdx)
  shell               Interactive Elixir shell
  help                Show this help message

Environment Variables:
  LEI_AIRGAPPED_MODE              Enable air-gapped mode (true/false)
  LEI_BASE_TEMP_DIR               Temp directory for git clones
  LEI_CRITICAL_CURRENCY_LEVEL     Weeks threshold for critical (default: 104)
  LEI_HIGH_CURRENCY_LEVEL         Weeks threshold for high (default: 52)
  LEI_MEDIUM_CURRENCY_LEVEL       Weeks threshold for medium (default: 26)
  LEI_CRITICAL_CONTRIBUTOR_LEVEL  Contributor threshold for critical (default: 2)
  LEI_SBOM_RISK_LEVEL             Risk when SBOM missing (default: medium)

Examples:
  # Analyze a mounted local repository
  docker run -v /path/to/repo:/workspace lei:latest scan

  # Analyze a remote repository (requires network)
  docker run lei:latest analyze https://github.com/user/repo

  # Get container SBOM
  docker run lei:latest sbom cyclonedx > container-sbom.json

Air-Gapped Usage:
  Mount git bundles or local repositories to /workspace for offline analysis.
  Set LEI_AIRGAPPED_MODE=true to skip network-dependent checks.

EOF
    ;;

  *)
    # Pass through to mix for custom commands
    exec mix "$@"
    ;;
esac
