# LEI Vibe-Coding Integration Research

## Executive Summary

This document analyzes integration opportunities between LowEndInsight (LEI) and the emerging "vibe coding" ecosystem: VS Code extensions, Cursor IDE, and GitHub Copilot. As AI-assisted development accelerates dependency adoption without traditional review, LEI's bus-factor risk analysis becomes critical infrastructure for maintaining supply chain health.

**Key Finding:** The Model Context Protocol (MCP) is the convergence point across all three platforms. A single `lei-mcp-server` serves Cursor's Agent, GitHub Copilot Chat, Copilot CLI, and any MCP-compatible tool. This should be the primary integration target.

**Critical Market Gap:** No existing tool combines bus-factor analysis + dependency manifest scanning + CI/CD governance + IDE integration. Socket.dev is closest but lacks contributor-depth analysis. LEI would be the first tool to give AI coding assistants access to bus-factor risk data when suggesting dependencies.

## LEI Risk Data Model

The extension surfaces these per-dependency fields from LEI's analysis:

| Metric | Description | Risk Thresholds |
|--------|-------------|-----------------|
| Functional Contributors | Contributors with meaningful commit share | <2 = critical, <3 = high, <5 = medium |
| Commit Currency | Weeks since last commit | >104 = critical, >52 = high, >26 = medium |
| Large Recent Commits | Code volatility percentage | >40% = critical, >30% = high, >20% = medium |
| Contributor Count | Total unique contributors | Configurable thresholds |
| SBOM Presence | Bill of materials artifact detection | Missing = configurable risk |
| Rolled-Up Risk | Highest risk across all dimensions | critical / high / medium / low |

---

## 1. VS Code Extension APIs for Dependency Warnings

### 1.1 Diagnostics API (Priority: Highest)

**Purpose:** Show warnings/errors directly on dependency declarations in manifest files.

**Key Methods:** `vscode.languages.createDiagnosticCollection()`, `DiagnosticCollection.set()`, severity mapping

**LEI Mapping:**
- `critical` -> `DiagnosticSeverity.Error` (red squiggle)
- `high` -> `DiagnosticSeverity.Warning` (yellow squiggle)
- `medium` -> `DiagnosticSeverity.Information` (blue squiggle)
- `low` -> `DiagnosticSeverity.Hint` (dots)

**Integration:** Parse `package.json`, `Cargo.toml`, `mix.exs`, `requirements.txt` to locate dependency declarations. Cross-reference against LEI risk cache. Warnings appear in the Problems panel and inline on dependency lines.

**Example Extensions Using This Pattern:** Snyk Security, ESLint, Stylelint

**Gotchas:** Diagnostics are ephemeral; must recompute on file changes. Requires parsing manifest files to compute exact line ranges.

### 1.2 CodeLens API

**Purpose:** Show inline risk scores above dependency declarations.

**Key Methods:** `registerCodeLensProvider()`, `provideCodeLenses()`, `resolveCodeLens()` (lazy resolution)

**LEI Display:** `lei: risk critical | 1 contributor | 68w stale` above each dependency line.

**Example:** Version Lens extension shows package versions as inline CodeLens.

**Gotchas:** Visually heavy in large manifests; lazy resolution critical for LEI's clone-and-analyze model. Consider making opt-in.

### 1.3 Hover Provider

**Purpose:** Show detailed risk breakdown when hovering over a dependency name.

**Key Methods:** `registerHoverProvider()`, `provideHover()` with MarkdownString support

**LEI Display:** Rich markdown table with contributor count, functional contributors, commit currency (weeks), recent commit volatility, SBOM status, and overall risk level.

**Gotchas:** Hover fires on every mouse movement; must cache LEI data aggressively. Sub-second response required.

### 1.4 Decorator API (Inline Annotations)

**Purpose:** Color-coded inline risk annotations on dependency lines.

**Key Methods:** `createTextEditorDecorationType()`, `setDecorations()`, `DecorationRenderOptions`

**LEI Display:** 4 decoration types (critical=red, high=orange, medium=yellow, low=green) with appended text like ` -- lei: critical`.

**Example:** Snyk Vuln Cost (archived) showed vulnerability counts inline using this pattern.

**Limitations:** Must re-apply on editor changes; `after.contentText` is plain text only.

### 1.5 WebView API (Rich Dashboard)

**Purpose:** Interactive dependency health dashboard with charts and detailed reports.

**Key Methods:** `createWebviewPanel()`, `postMessage()`/`onDidReceiveMessage`, `asWebviewUri()`

**LEI Use:** Build a dashboard showing risk heatmaps, per-dependency cards, contributor trend charts, and project-wide health summary.

**Gotchas:** Expensive memory-wise; all resources must use `asWebviewUri()`; CSP restrictions apply. Defer until data model is stable.

### 1.6 Tree View API (Sidebar Panel)

**Purpose:** Persistent sidebar panel showing all dependencies grouped by risk severity.

**Key Methods:** `registerTreeDataProvider()`, `getTreeItem()`, `getChildren()`, `onDidChangeTreeData`

**LEI Structure:**
```
LEI Dependencies
  Critical (3)
    some-risky-lib (1 contributor, 78w stale)
    another-pkg (abandoned)
  High (5)
    ...
  Medium (12)
    ...
  Low (45)
    ...
```

Right-click context menus for "View Report", "Re-analyze", "Open Repository".

### 1.7 Status Bar (Global Health Score)

**Purpose:** Show aggregate project dependency health at a glance.

**LEI Display:**
- `$(shield) LEI: 3 critical, 5 high` (error background)
- `$(check) LEI: All deps healthy` (green)
- `$(sync~spin) LEI: Analyzing...` (during scan)

Click opens the dashboard or Problems panel. Minimal code, high visibility.

### 1.8 FileSystemWatcher (Dependency Change Detection)

**Purpose:** Watch manifest and lock files for changes, trigger re-analysis.

**Watch Pattern:** `{**/package.json,**/Cargo.lock,**/mix.lock,**/yarn.lock,**/requirements.txt,**/Cargo.toml,**/mix.exs}`

**Key Events:** `onDidChange`, `onDidCreate`, `onDidDelete`

**Best Practice:** Debounce re-analysis (2000ms) to avoid thrashing on rapid file changes.

**Limitation:** Linux inotify limits can be exceeded in large monorepos.

### 1.9 Commands and Activation Events

**Lazy Activation Strategy:**
```json
{
  "activationEvents": [
    "workspaceContains:**/package.json",
    "workspaceContains:**/Cargo.toml",
    "workspaceContains:**/mix.exs",
    "workspaceContains:**/requirements.txt",
    "onView:leiDependencyHealth"
  ]
}
```

**Core Commands:** `lei.analyzeProject`, `lei.showDashboard`, `lei.analyzeDependency`, `lei.clearCache`

**Progress UI:** Use `vscode.window.withProgress()` with cancellation tokens for long-running analysis.

### 1.10 Language Server Protocol (LSP) Assessment

**Recommendation: NOT recommended for MVP.**

LSP adds significant architectural complexity (client/server split, JSON-RPC) and most of LEI's integration surfaces (Tree Views, WebView, Status Bar) are VS Code-specific APIs not expressible through LSP. LEI is a project analysis tool, not a traditional language server.

**Consider LSP later when:**
- Performance bottlenecks require process isolation for heavy cloning/analysis
- Multi-editor support is desired (Neovim, Emacs, JetBrains)
- LEI server needs to remain in Rust/Elixir without TypeScript rewrite

**Intermediate approach:** Spawn LEI as a child process with custom JSON protocol (stdin/stdout) for isolation without full LSP overhead.

---

## 2. Cursor IDE Integration

### 2.1 Extension Compatibility

Cursor is a VS Code fork. ~99% of VS Code extensions work in Cursor, including diagnostics, file watchers, and inline decorations. However, the VS Code Chat Participant API (`vscode.chat.createChatParticipant`) requires Copilot and **does not function in Cursor**. Cursor uses its own AI stack.

**Implication:** A standard VS Code extension for diagnostics/tree views/hover works in both VS Code and Cursor. Chat-specific features require separate strategies.

### 2.2 Cursor Rules (.cursor/rules/) for Static Context Injection

Cursor's `.cursor/rules/*.mdc` files inject context into all AI interactions. LEI can generate a rules file containing current dependency risk data:

**File:** `.cursor/rules/dependency-health.mdc`
```markdown
---
description: Dependency health and bus-factor risk data from LowEndInsight
globs: ["mix.exs", "mix.lock", "package.json", "Cargo.toml", "requirements.txt"]
alwaysApply: false
---
# Dependency Risk Context

## Critical Risk
- **some-library** (contributor_count: 1, last_commit: 78 weeks ago, bus-factor: critical)

## High Risk
- **another-lib** (functional_contributors: 2, commit_currency: 52+ weeks)

When suggesting code that imports these packages, warn about maintenance risk.
When adding new dependencies, suggest running `lei analyze <repo_url>` first.
```

**Complexity:** Low (file generation only).
**UX Impact:** High for vibe coding -- invisible, always-on risk awareness without user action.
**Limitation:** Static files; must regenerate when dependencies change. CI/CD or git hooks can automate.

### 2.3 MCP Server (Primary Integration -- Cross-Platform)

**This is the single most impactful integration.** MCP is Cursor's primary extensibility mechanism for dynamic AI context, and it is also the replacement for deprecated GitHub Copilot Extensions.

**LEI MCP Server Tools:**

| Tool Name | Description | Input | Output |
|-----------|-------------|-------|--------|
| `analyze_repo` | Full LEI analysis on a Git URL | `{ "url": "https://..." }` | LEI JSON report |
| `scan_dependencies` | Scan project dependency manifests | `{ "path": "/path/to/project" }` | Risk summary for all deps |
| `check_dependency` | Check single dependency health | `{ "package": "serde", "registry": "crates" }` | Single-dep risk report |
| `get_risk_summary` | Human-readable risk summary | `{ "path": "/path/to/project" }` | Markdown risk summary |

**Configuration in `.cursor/mcp.json`:**
```json
{
  "mcpServers": {
    "lei": {
      "command": "lei-mcp-server",
      "args": ["--project-dir", "."]
    }
  }
}
```

When a developer asks Cursor "should I use this library?" or "add X dependency", the Agent automatically invokes LEI tools. The developer can also explicitly say "use lei to check this dependency."

**Feasibility:** Available now. MCP SDKs exist for Rust, Node.js, Python, Go.
**Complexity:** Medium. Requires building a server binary that wraps LEI analysis.
**UX Impact:** Very high. The AI silently consults LEI when relevant.

### 2.4 Cursor @Docs Indexing

If LEI exposes risk reports as web-accessible pages, Cursor can index them via Settings > Features > Docs. Developers reference `@lei-risk-report` in chat.

**UX Impact:** Moderate. Requires manual `@Doc` reference, breaking the vibe-coding flow. Less seamless than MCP.

### 2.5 Intercepting Cursor's AI Code Generation

There is no hook to intercept Cursor's inline completion (Tab) suggestions. However, a layered defense approach works:

1. **Rules injection (2.2):** Risk context prepended to all AI prompts
2. **MCP tools (2.3):** Agent calls LEI during multi-step reasoning
3. **Post-edit diagnostics:** VS Code extension detects new imports via `onDidChangeTextDocument` and shows warnings
4. **File watchers:** Watch dependency manifests for changes, trigger re-analysis

---

## 3. GitHub Copilot Integration

### 3.1 Current Extensibility Landscape

| Mechanism | Status | Scope |
|-----------|--------|-------|
| GitHub App-based Copilot Extensions | **Deprecated** (Nov 2025) | N/A |
| MCP Servers for Copilot Chat | **GA** | VS Code, Visual Studio, JetBrains, Eclipse, Xcode |
| VS Code Chat Participant API | **Stable** | VS Code only |
| GitHub Copilot SDK | **Technical Preview** (Jan 2026) | Any application |
| Copilot CLI plugins with MCP | **GA** (Jan 2026) | CLI |

**Critical:** The MCP server built for Cursor (Section 2.3) is the same artifact needed for Copilot. Build once, deploy everywhere.

### 3.2 VS Code Chat Participant (@lei)

Register a `@lei` mention in Copilot Chat. When a user types `@lei is this dependency safe?`, the handler invokes LEI analysis and returns formatted results.

```json
{
  "chatParticipants": [{
    "id": "lei.dependency-health",
    "name": "lei",
    "fullName": "LowEndInsight",
    "description": "Analyze dependency bus-factor risk and maintenance health"
  }]
}
```

**Limitation:** VS Code only. For cross-IDE support, the MCP approach is superior.

### 3.3 Copilot Custom Instructions (Static Context)

Similar to Cursor rules, Copilot supports instruction files:

**File:** `.github/instructions/dependency-risk.instructions.md`
```markdown
---
applyTo: "**/mix.exs,**/package.json,**/requirements.txt,**/Cargo.toml"
---
# LowEndInsight Dependency Risk Data

When suggesting dependencies or reviewing code that adds new imports:

## Flagged Dependencies (auto-generated by `lei scan`)
- httpoison: contributor_risk=low, commit_currency=low, overall=low
- some_risky_lib: contributor_risk=critical (1 contributor), commit_currency=52+ weeks, overall=critical

Always warn when suggesting a dependency with critical or high bus-factor risk.
```

**Feasibility:** Available now.
**UX Impact:** High. Invisible to developers but shapes Copilot's suggestions. Works in VS Code, Visual Studio, and any IDE reading `.github/` instruction files.

### 3.4 Copilot CLI Integration

The same `lei-mcp-server` registered in `~/.copilot/config` or `.github/copilot/mcp.json`:

```bash
$ gh copilot "check the bus-factor risk of my project dependencies"
# Copilot CLI invokes lei MCP tools, returns risk summary
```

**Feasibility:** Available now (January 2026 update).

### 3.5 Intercepting Copilot's Dependency Suggestions

No pre-completion hook exists in Copilot's inline suggestion pipeline. Available approaches:

| Hook Type | Availability | Mechanism |
|-----------|-------------|-----------|
| Pre-inline-completion interception | Not available | Not on roadmap |
| Post-completion detection | Available now | `onDidChangeTextDocument` |
| Pre-chat-response tool call | Available now | MCP tools / Chat Participant |
| Dependency file change watcher | Available now | `createFileSystemWatcher` |

---

## 4. Existing Tools and Gap Analysis

### 4.1 Competitive Landscape

#### Vulnerability Scanners (Reactive, Backward-Looking)
- **Snyk:** Known CVEs and deprecated packages. No bus-factor coverage.
- **npm audit / cargo audit:** CVE/advisory scanners. 65% bypass rate due to alert fatigue.
- **Dependabot:** Version staleness + known vulnerabilities. Cannot assess maintainer likelihood to release patches.

#### Supply Chain Analysis
- **Socket.dev:** Behavioral analysis (network access, filesystem ops, typosquatting). "Maintenance" score is coarse -- not git-level contributor analysis. Has an MCP server already.
- **Endor Labs:** Reachability analysis, health assessment (proprietary). Finding: 80% of AI-suggested dependencies contain risks.

#### OpenSSF Tools
- **Scorecard:** 18 automated security checks (0-10). "Maintained" check is binary (active/inactive within 90 days). "Contributors" check measures organizational diversity, NOT bus-factor.
- **Criticality Score:** Identifies how critical projects are to ecosystem (0-1). Uses contributor count as signal of importance, not risk.

#### Bus-Factor Research Tools (Single-Repo, Academic)
- **JetBrains Bus Factor Explorer:** Repository/module/file-level bus factor with turnover simulation. Does NOT analyze transitive dependencies. No CI/CD integration.
- **Truck-Factor (aserg-ufmg):** Foundational research. 65% of GitHub projects have bus factor <= 2. No dependency scanning.
- **Knowledge Islands:** Multi-level truck factor visualization. Single project only.
- **csDetector:** Binary classification (smell present/absent), not quantitative scoring.

#### Community Health Frameworks
- **CHAOSS:** Metrics framework including "Contributor Absence Factor". Requires Elasticsearch/Kibana/GrimoireLab infrastructure. Designed for maintainers, not dependency consumers.
- **Bitergia Risk Radar:** Philosophically closest to LEI. Enterprise SaaS (expensive, proprietary).

#### AI/Vibe-Coding Tools
- **Socket MCP Server:** Allows AI assistants to query Socket API. Provides supply chain/quality/maintenance scores. Maintenance score is not granular bus-factor analysis.
- **SlopGuard:** Detects AI hallucinated packages (namespace squatting, typosquatting). Validates package exists; LEI validates package is healthy.

### 4.2 Capability Comparison Matrix

| Capability | LEI | Socket | Snyk | Scorecard | Bus Factor Explorer |
|---|---|---|---|---|---|
| **Functional contributor analysis** | Yes | No | No | No | Own repo only |
| **Configurable risk thresholds** | Yes | No | No | No | No |
| **Dependency manifest scanning** | Yes | Yes | Yes | No | No |
| **Bus-factor on transitive deps** | Yes | No | No | No | No |
| **CI/CD pipeline gating** | Yes | Partial | Partial | Partial | No |
| **Open-source, transparent** | BSD-3 | No | No | Apache-2 | MIT |
| **Configurable commit currency** | Yes | No | No | Binary (90d) | No |
| **SBOM presence detection** | Yes | No | No | No | No |
| **Recent commit volatility** | Yes | No | No | No | No |
| **AI/MCP integration** | Planned | Yes | No | No | No |
| **IDE extension** | Planned | Yes | Yes | No | JetBrains |

### 4.3 LEI's Unique Position

**No tool currently combines:** bus-factor analysis + dependency manifest scanning + CI/CD governance + open-source transparency + IDE integration.

Three competitive categories where LEI is differentiated:

1. **vs. Vulnerability Scanners** (Snyk, npm audit): They are reactive/backward-looking. LEI is predictive -- assesses capacity to respond to future problems. A project with zero CVEs but one contributor and two years of inactivity is invisible to Snyk but flagged as critical by LEI.

2. **vs. Bus-Factor Research Tools** (Bus Factor Explorer, Truck-Factor): They analyze individual repositories as academic exercises. LEI analyzes dependency trees and produces actionable governance output.

3. **vs. Enterprise Platforms** (Bitergia, Endor Labs): Commercial, proprietary, OSPO-focused. LEI is open-source, developer-focused, CI/CD-integrated.

---

## 5. Recommended Implementation Roadmap

### Phase 1: Static Context Injection (1-2 weeks)

**Deliverable:** `lei generate-rules` command that outputs:
- `.cursor/rules/dependency-health.mdc` (Cursor)
- `.github/instructions/dependency-risk.instructions.md` (Copilot)

**Coverage:** Cursor rules, Copilot instructions
**Complexity:** Low (file templating from existing LEI data)
**Vibe Coding Impact:** High (invisible, always-on risk awareness)

Add to CI/CD pipeline to regenerate on dependency changes.

### Phase 2: MCP Server (4-6 weeks)

**Deliverable:** `lei-mcp-server` binary with stdio transport

**Tools:** `analyze_repo`, `scan_dependencies`, `check_dependency`, `get_risk_summary`

**Coverage:** Cursor Agent, Copilot Chat, Copilot CLI, any MCP-compatible tool
**Complexity:** Medium
**Vibe Coding Impact:** Very high (AI proactively consults LEI)

### Phase 3: VS Code Extension with Diagnostics (3-4 weeks)

**Deliverable:** VS Code extension providing:
- Diagnostic warnings on risky dependency declarations
- Tree view sidebar panel grouped by risk severity
- Status bar aggregate health score
- Hover provider with detailed risk breakdown
- FileSystemWatcher for automatic re-analysis

**Coverage:** VS Code + Cursor (as VS Code extension)
**Complexity:** Medium
**Vibe Coding Impact:** High (visual feedback without interrupting flow)

### Phase 4: VS Code Chat Participant (2-3 weeks, after Phase 3)

**Deliverable:** `@lei` chat participant in Copilot Chat

**Coverage:** VS Code with Copilot only (not Cursor, not JetBrains)
**Complexity:** Medium
**Vibe Coding Impact:** Moderate (requires explicit interaction)
**Note:** Lower priority than MCP because MCP covers more surfaces.

### Phase 5: Copilot SDK Agent (Speculative, 4-8 weeks)

**Deliverable:** Standalone LEI agent via Copilot SDK (technical preview as of Jan 2026)

**Coverage:** Custom environments beyond IDE
**Complexity:** High (API may change)

### Implementation Priority Summary

```
Phase 1: Static Rules ──────> Immediate value, low effort
Phase 2: MCP Server ────────> Highest impact, cross-platform
Phase 3: VS Code Extension ─> Visual integration, broad reach
Phase 4: Chat Participant ──> VS Code-specific polish
Phase 5: Copilot SDK ───────> Future extensibility
```

---

## 6. Architecture: Real-Time Validation of AI-Suggested Dependencies

```
[AI suggests code] ──> [onDidChangeTextDocument fires]
       │
       v
[Parse change for imports/deps]
       │
       v
[Look up in LEI risk cache]     <── [lei scan generates cache on project open / dep file change]
       │
       v
[If risky: show diagnostic]     ──> [Warning squiggle + hover detail + code action "View LEI Report"]
[If unknown: queue async check] ──> [Call LEI MCP server] ──> [Update cache + show diagnostic]
```

This architecture provides sub-second response for cached dependencies (common case) and async resolution for unknown packages.

### Context Injection Matrix (Cross-Platform)

| Platform | Mechanism | File Location | Trigger |
|----------|-----------|---------------|---------|
| Cursor | `.cursor/rules/*.mdc` | Project root | Glob match on active files |
| Copilot (VS Code) | `.github/copilot-instructions.md` | Project root | Always active |
| Copilot (VS Code) | `.github/instructions/*.instructions.md` | Project root | Glob match |
| Copilot CLI | MCP server config | `~/.copilot/config` | Agent mode |
| Both | MCP tool results | Runtime | On-demand |

---

## Sources

- [VS Code Extension API - Diagnostics](https://code.visualstudio.com/api/references/vscode-api#languages.createDiagnosticCollection)
- [VS Code Extension API - CodeLens](https://code.visualstudio.com/api/references/vscode-api#languages.registerCodeLensProvider)
- [VS Code Extension API - WebView](https://code.visualstudio.com/api/extension-guides/webview)
- [VS Code Extension API - Tree View](https://code.visualstudio.com/api/extension-guides/tree-view)
- [VS Code Chat Participant API](https://code.visualstudio.com/api/extension-guides/ai/chat)
- [Cursor Rules Documentation](https://cursor.com/docs/context/rules)
- [Cursor MCP Documentation](https://cursor.com/docs/context/mcp)
- [GitHub Copilot Extensions Deprecation](https://github.blog/changelog/2025-09-24-deprecate-github-copilot-extensions-github-apps/)
- [GitHub Copilot Custom Instructions](https://docs.github.com/copilot/customizing-copilot/adding-custom-instructions-for-github-copilot)
- [Extending Copilot Chat with MCP Servers](https://docs.github.com/copilot/customizing-copilot/using-model-context-protocol/extending-copilot-chat-with-mcp)
- [GitHub Copilot SDK](https://github.blog/news-insights/company-news/build-an-agent-into-any-app-with-the-github-copilot-sdk/)
- [GitHub Copilot CLI Update (Jan 2026)](https://github.blog/changelog/2026-01-14-github-copilot-cli-enhanced-agents-context-management-and-new-ways-to-install/)
- [MCP Specification - Transports](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
- [OpenSSF Scorecard](https://scorecard.dev/)
- [Socket.dev](https://socket.dev/)
- [CHAOSS Community Health Analytics](https://chaoss.community/)
- [Endor Labs - State of Dependency Management 2025](https://www.endorlabs.com/)
- [Version Lens VS Code Extension](https://marketplace.visualstudio.com/items?itemName=pflannery.vscode-versionlens)
- [Snyk VS Code Extension](https://marketplace.visualstudio.com/items?itemName=snyk-security.snyk-vulnerability-scanner)
- [Socket MCP Server](https://mcp.socket.dev/)
