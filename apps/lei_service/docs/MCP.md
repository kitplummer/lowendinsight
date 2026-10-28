# LowEndInsight as an MCP server

> **Beta.** `serverInfo.version` is the release you are talking to. Tool
> names, arguments and output may change between betas; breaking changes are
> listed in the [CHANGELOG](../../lowendinsight/CHANGELOG.md).

`https://lowendinsight.dev/mcp` puts dependency facts in an agent's tool
list. That is the only way an agent comes to use them: it does not browse, it
uses what it was given.

A model's training data has a cutoff, so it cannot know whether a package is
maintained *now*. That gap does not close with the next model -- it moves
forward with it. This answers it from the repository as it stands today. It is
also why the tool descriptions lead with when to call them and what goes wrong
without them, rather than with a risk score: an agent will repeat "last commit
fourteen months ago, one functional contributor" to its user, and will not
lean on a rating whose derivation it cannot inspect.

## Connect

It needs a `lei_` API key with the `analyze` scope, sent as
`Authorization: Bearer lei_...`. Keys are free during the beta:
https://lowendinsight.dev/signup. An agent that bought credits over MPP uses
the `Lei-Api-Key` its payment returned.

**Claude Code**

```bash
claude mcp add --transport http lowendinsight https://lowendinsight.dev/mcp \
  --header "Authorization: Bearer lei_..."
```

**Cursor** (`~/.cursor/mcp.json`)

```json
{
  "mcpServers": {
    "lowendinsight": {
      "url": "https://lowendinsight.dev/mcp",
      "headers": { "Authorization": "Bearer lei_..." }
    }
  }
}
```

**VS Code** (`.vscode/mcp.json`)

```json
{
  "inputs": [
    { "type": "promptString", "id": "lei-key", "description": "LowEndInsight API key", "password": true }
  ],
  "servers": {
    "lowendinsight": {
      "type": "http",
      "url": "https://lowendinsight.dev/mcp",
      "headers": { "Authorization": "Bearer ${input:lei-key}" }
    }
  }
}
```

Any other client that speaks Streamable HTTP and can send a header works the
same way. **A client that can only connect with OAuth cannot connect yet**;
the server does not offer OAuth.

## Tools

**`check_packages(dependencies)`** -- packages by ecosystem, name and version
(`npm`, `pypi`, `hex`, `cargo`, `gem`, `composer`, `go`). This is
`POST /v1/analyze/batch`. A package already analysed comes back with its risk
now. One that is not is queued and comes back `pending`; asking about it again
while it is pending is not charged. Send the whole set being weighed in one
call.

**`analyze_repositories(urls)`** -- git repository URLs, for a fork, a vendored
library, or a project with no registry release. This is `POST /v1/analyze`,
blocking for up to 30 seconds. Work that does not finish in that time comes
back `incomplete`, with a `uuid` and a `next` field saying to collect it.

**`get_analysis(uuid)`** -- collects an `incomplete` result. This is
`GET /v1/analyze/{uuid}`, and it is not charged: the analysis was paid for when
it was requested. Calling `analyze_repositories` again instead is charged
again, which is why the tool descriptions and `next` both say to collect.

A report the service could not produce -- a repository that does not exist,
or could not be cloned -- comes back with its risk `undetermined` and the
reason in `data.error`. That is a failure to look, not a finding about the
dependency.

## Billing and limits

Each call is billed exactly as the route it mirrors, by `Lei.Payments.Gate`,
and every result carries the same `billing` block. During the beta analysis
is free, within each account's monthly allowance.

Refusals are tool results with `isError: true`, worded for a model rather
than as HTTP statuses, because an MCP client has nowhere to handle a 402:

- **A spent allowance** -- says nothing was analysed or charged, and where to
  upgrade.
- **Short credits** -- says how many to top up, and where.
- **Billing unavailable** -- says to try again shortly.
- **Invalid arguments, or work that could not be queued** -- says what was
  wrong. Work that could not be queued is credited back.

Every request, `tools/list` included, counts against the key's one allowance:
the same 60 a minute the API's routes share. Over it is an HTTP 429 with
`Retry-After`.

## Protocol

Streamable HTTP, stateless, JSON responses only. Protocol `2025-06-18` and
`2025-03-26`. `POST` only: there are no sessions, no `Mcp-Session-Id` and no
event stream, so `GET` and `DELETE` are 405. JSON-RPC batches are refused, as
2025-06-18 requires. A request with an `Origin` header from another site is
refused, against DNS rebinding.

| status | when |
|---|---|
| 401 | no key, or an invalid one, with a `WWW-Authenticate: Bearer` challenge |
| 403 | a key without the `analyze` scope, an inactive organization, or a foreign `Origin` |
| 429 | over the rate limit |

## Moving from `clients/mcp/lei_mcp.py`

The local stdio client was retired in favour of this server. Remove its entry
from your client's configuration and add the URL above with the same key.

| `lei_mcp.py` | `/mcp` |
|---|---|
| `analyze_repository(url)` | `analyze_repositories(urls: [url])` |
| `analyze_dependencies(urls)` | `analyze_repositories(urls)` |
| -- | `check_packages(dependencies)` |
| -- | `get_analysis(uuid)` |
| `LEI_API_KEY` | `Authorization: Bearer` header |
| `LEI_BASE_URL` | the URL itself |

## The registry listing

`server.json` at the repository root is the listing for the
[MCP Registry](https://registry.modelcontextprotocol.io), under the name
`io.github.kitplummer/lowendinsight`. The registry checks who owns the name,
not what the listing says, so `test/lei_service/mcp_registry_test.exs` holds
its version, URL and header to the server.

Published by hand, by the owner of the `kitplummer` GitHub account, with the
registry's `mcp-publisher` from the repository root:

```bash
mcp-publisher login github     # a device flow in the browser; no token on the command line
mcp-publisher publish
```

The name is a GitHub namespace rather than `dev.lowendinsight/...` because the
registry's DNS login takes its private key only as a command-line argument,
and secrets here do not go in as arguments.

Publish again after each release: the version in `server.json` follows the
release, and the test fails until it does.

## Verified

`test/lei_service/mcp_test.exs` drives `/mcp` through `LeiService.Endpoint`,
which is what production serves. The smoke test, which gates every deploy and
runs every 15 minutes in `monitor`, initializes a session against production,
lists the tools and calls `get_analysis`.
