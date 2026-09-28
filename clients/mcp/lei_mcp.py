#!/usr/bin/env python3
"""LowEndInsight as an MCP tool.

Puts dependency facts in an agent's tool list, which is the only way an agent
comes to use them: it does not browse, it uses what it was given.

What this is for, and it is narrow: a model's training data has a cutoff, so it
cannot know whether a package is maintained *now*. That gap does not close with
the next model -- it moves forward with it. This answers it from the repository
as it stands today.

No third-party imports, deliberately. The subject here is dependency risk; asking
anyone to install a package tree to run it would be a poor advertisement, and one
file of standard library is auditable before it is trusted.

    LEI_API_KEY   an API key. Free during beta: https://lowendinsight.dev/signup
    LEI_BASE_URL  defaults to https://lowendinsight.dev

Wire it up (Claude Desktop, Cursor, and most runtimes take this shape):

    {"mcpServers": {"lowendinsight": {
       "command": "python3",
       "args": ["/path/to/clients/mcp/lei_mcp.py"],
       "env": {"LEI_API_KEY": "lei_..."}}}}

Speaks MCP over stdio: newline-delimited JSON-RPC 2.0 on stdin and stdout.
Nothing but protocol goes to stdout -- diagnostics go to stderr, because a stray
print corrupts the stream and presents as an agent that hangs.
"""

import json
import os
import sys
import urllib.error
import urllib.request

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "lowendinsight"
SERVER_VERSION = "0.1.0"

BASE_URL = os.environ.get("LEI_BASE_URL", "https://lowendinsight.dev").rstrip("/")
API_KEY = os.environ.get("LEI_API_KEY", "").strip()
TIMEOUT = float(os.environ.get("LEI_TIMEOUT_SECONDS", "120"))

# Written for the agent choosing a tool, not for a catalogue. The reason to call
# it is the reason it exists: a cutoff.
TOOLS = [
    {
        "name": "analyze_repository",
        "description": (
            "Facts about a source repository as it stands today: when it was last "
            "committed to, how many people actually maintain it, how much of its "
            "recent work looks AI-generated, and a risk rating derived from those. "
            "Use this before suggesting or adding a dependency, or when asked "
            "whether a library is maintained -- your training data has a cutoff and "
            "cannot know the current state of a project."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "Repository URL, e.g. https://github.com/owner/name",
                }
            },
            "required": ["url"],
        },
    },
    {
        "name": "analyze_dependencies",
        "description": (
            "The same facts for several repositories at once -- the dependencies of "
            "a project, a shortlist of candidate libraries, or the packages named in "
            "a manifest. Prefer this over repeated single calls: results are shared "
            "and cached, so a batch is cheaper and faster than its parts."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "urls": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Repository URLs.",
                }
            },
            "required": ["urls"],
        },
    },
]


def log(message):
    """stderr only. stdout carries protocol and nothing else."""
    print(message, file=sys.stderr, flush=True)


def post(path, payload):
    """POST JSON, returning (parsed, None) or (None, human-readable failure)."""
    if not API_KEY:
        return None, (
            "LEI_API_KEY is not set, so this tool cannot call the service.\n"
            "An account is free during the beta -- analysis is not charged for -- "
            "at https://lowendinsight.dev/signup . Put the key in the MCP server's "
            "env as LEI_API_KEY."
        )

    request = urllib.request.Request(
        BASE_URL + path,
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + API_KEY,
            "User-Agent": "lowendinsight-mcp/" + SERVER_VERSION,
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.loads(response.read().decode()), None
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")[:600]

        # Said in terms of what the agent should do, not what the status was.
        if error.code == 401:
            return None, "The service rejected LEI_API_KEY (401). The key is wrong or revoked."
        if error.code == 402:
            return None, (
                "The service asked for payment (402). This key has no allowance left, "
                "or none is attached to it. During the beta each account gets a monthly "
                "allowance at no charge; this one is exhausted.\n" + body
            )
        if error.code == 429:
            return None, "Rate limited by the service (429). Retry in a minute."
        return None, "The service answered %d.\n%s" % (error.code, body)
    except urllib.error.URLError as error:
        return None, "Could not reach %s: %s" % (BASE_URL, error.reason)
    except (TimeoutError, OSError) as error:
        return None, "Could not reach %s: %s" % (BASE_URL, error)
    except json.JSONDecodeError as error:
        return None, "The service answered with something that is not JSON: %s" % error


def summarise(report):
    """One repository's facts, recency first.

    Order is the argument: the dates and the people are what a model cannot
    know, and the risk rating is derived from them. Leading with the rating
    invites an agent to repeat a number it cannot justify.
    """
    data = report.get("data") or {}
    results = data.get("results") or {}
    git = data.get("git") or {}
    lines = []

    repo = data.get("repo") or report.get("header", {}).get("repo") or "unknown"
    lines.append("## %s" % repo)

    # First, and on its own. A repository the service could not analyse comes
    # back with everything undetermined and the reason in data.error; rendering
    # only the rating tells the agent "undetermined risk", which reads as a
    # finding about the dependency rather than a failure to look at it.
    if data.get("error"):
        lines.append("- **not analysed**: %s" % data["error"])
        return "\n".join(lines)

    last = git.get("last_commit_date") or results.get("last_commit_date")
    if last:
        lines.append("- last commit: %s" % last)
    if git.get("last_substantive_commit_date"):
        lines.append("- last substantive commit: %s" % git["last_substantive_commit_date"])
    if results.get("commit_currency_weeks") is not None:
        lines.append("- weeks since that commit: %s" % results["commit_currency_weeks"])

    if results.get("contributor_count") is not None:
        lines.append("- contributors: %s" % results["contributor_count"])
    if results.get("functional_contributors") is not None:
        lines.append(
            "- functional contributors (people doing the work): %s"
            % results["functional_contributors"]
        )

    agentic = results.get("agentic_contribution_ratio")
    if agentic is None:
        agentic = (data.get("agentic") or {}).get("agentic_contribution_ratio")
    if agentic is not None:
        lines.append("- recent commits that look AI-generated: %s" % agentic)

    if data.get("risk"):
        lines.append("- overall risk rating: %s" % data["risk"])

    for key, label in (
        ("commit_currency_risk", "currency"),
        ("contributor_risk", "contributor count"),
        ("functional_contributors_risk", "functional contributors"),
        ("large_recent_commit_risk", "large recent commit"),
        ("sbom_risk", "sbom"),
    ):
        if results.get(key):
            lines.append("  - %s risk: %s" % (label, results[key]))

    return "\n".join(lines)


def render(response):
    """The service's answer, as text an agent can quote back to its user."""
    reports = (response.get("report") or {}).get("repos")

    if not reports:
        # An empty answer is not a clean one: it means nothing was examined.
        return (
            "The service returned no reports. Nothing was analysed, which is not the "
            "same as nothing being wrong.\n\n" + json.dumps(response)[:800]
        ), True

    chunks = [summarise(report) for report in reports]

    # If nothing at all was determined, that is a failure to answer rather than
    # an answer. The caller marks it as an error so the agent does not repeat
    # "undetermined" to its user as though it meant low risk.
    determined = [
        report
        for report in reports
        if not ((report.get("data") or {}).get("error"))
    ]

    metadata = response.get("metadata") or {}
    if metadata.get("times"):
        chunks.append("(%s)" % json.dumps(metadata["times"]))

    return "\n\n".join(chunks), len(determined) == 0


def call_tool(name, arguments):
    if name == "analyze_repository":
        url = (arguments or {}).get("url")
        if not url:
            return True, "analyze_repository needs a 'url'."
        urls = [url]
    elif name == "analyze_dependencies":
        urls = (arguments or {}).get("urls") or []
        if not urls:
            return True, "analyze_dependencies needs a non-empty 'urls' array."
    else:
        return True, "No such tool: %s" % name

    response, failure = post("/v1/analyze", {"urls": urls})
    if failure:
        return True, failure

    text, nothing_determined = render(response)
    return nothing_determined, text


def handle(message):
    """Returns a reply, or None for a notification (which must not be answered)."""
    method = message.get("method")
    message_id = message.get("id")

    # No id means a notification. Replying to one corrupts the stream.
    if message_id is None:
        return None

    def result(payload):
        return {"jsonrpc": "2.0", "id": message_id, "result": payload}

    if method == "initialize":
        return result(
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            }
        )

    if method == "tools/list":
        return result({"tools": TOOLS})

    if method == "tools/call":
        params = message.get("params") or {}
        is_error, text = call_tool(params.get("name"), params.get("arguments"))
        return result({"content": [{"type": "text", "text": text}], "isError": is_error})

    if method == "ping":
        return result({})

    # Answered, not ignored. A client waiting for a reply it never gets presents
    # as an agent that has hung.
    return {
        "jsonrpc": "2.0",
        "id": message_id,
        "error": {"code": -32601, "message": "Method not found: %s" % method},
    }


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            message = json.loads(line)
        except json.JSONDecodeError as error:
            log("ignoring unparseable line: %s" % error)
            continue

        try:
            reply = handle(message)
        except Exception as error:  # noqa: BLE001 - a crash here hangs the agent
            log("handler failed: %r" % error)
            reply = {
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "error": {"code": -32603, "message": "Internal error: %r" % error},
            }
            if reply["id"] is None:
                continue

        if reply is not None:
            sys.stdout.write(json.dumps(reply) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
