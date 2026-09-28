# LowEndInsight as an MCP tool

Puts dependency facts in an agent's tool list. That is the only way an agent
comes to use them: it does not browse, it uses what it was given.

## Why it exists

A model's training data has a cutoff, so it cannot know whether a package is
maintained *now*. That gap does not close with the next model — it moves forward
with it. This answers it from the repository as it stands today.

Which is also why the tool descriptions lead with recency and the people doing
the work, rather than with a risk score. An agent asked to justify a
recommendation will not lean on a rating whose derivation it cannot inspect; it
will happily repeat "last commit fourteen months ago, one functional
contributor".

## Install

One file, no dependencies. Copy it anywhere, or point at it in the checkout.

```json
{
  "mcpServers": {
    "lowendinsight": {
      "command": "python3",
      "args": ["/path/to/lowendinsight/clients/mcp/lei_mcp.py"],
      "env": { "LEI_API_KEY": "lei_..." }
    }
  }
}
```

That shape works in Claude Desktop, Cursor, and most runtimes that load MCP
servers from configuration.

| variable | |
|---|---|
| `LEI_API_KEY` | required. Free during the beta: https://lowendinsight.dev/signup |
| `LEI_BASE_URL` | defaults to `https://lowendinsight.dev` |
| `LEI_TIMEOUT_SECONDS` | defaults to 120 |

## Tools

**`analyze_repository(url)`** — one repository. Last commit, contributors,
functional contributors, the proportion of recent commits that look
AI-generated, and the risk ratings derived from those.

**`analyze_dependencies(urls)`** — several at once. Prefer it over repeated
single calls: reports are shared and cached, so a batch is cheaper and faster
than its parts.

## No dependencies, deliberately

The subject here is dependency risk. Asking anyone to install a package tree to
run it would be a poor advertisement, and one file of standard library can be
read before it is trusted.

## What it does when it cannot answer

Every failure says what to do rather than what went wrong:

- no `LEI_API_KEY` — names the variable, and says an account is free during beta
- `401` — the key is wrong or revoked
- `402` — the allowance is exhausted
- service unreachable — names the host it could not reach
- **a repository the service could not analyse** — reports `not analysed` with
  the reason, and marks the call an error

That last one matters most. An unanalysable repository comes back with every
field undetermined; rendering only the rating would tell the agent "undetermined
risk", which reads as a finding about the dependency rather than a failure to
look at it.

## Verified

`apps/lei_service/test/lei_service/mcp_server_test.exs` drives the real process
over stdio — initialize, tools/list, tools/call, notifications, unknown methods —
because the thing under test is a protocol conversation. A test that grepped this
file for tool names would pass for a server that never answers `initialize`.
