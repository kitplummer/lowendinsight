import * as vscode from "vscode";
import { AnalyzedDependency, RiskLevel } from "./types";
import { getManifestType } from "./manifestParser";

const RISK_EMOJI: Record<RiskLevel, string> = {
  critical: "!!",
  high: "! ",
  medium: "~ ",
  low: "ok",
};

// Everything in a hover except the labels comes from the API, and contributor
// names come from git commit authors -- anyone's to choose. Rendered as plain
// Markdown text, never trusted: a trusted MarkdownString runs `command:` links,
// so an author named like one could run a VS Code command from a hover.
function text(value: unknown): string {
  return String(value ?? "unknown").replace(/[\\`*_{}[\]()#+\-.!|<>]/g, "\\$&");
}

export class LeiHoverProvider implements vscode.HoverProvider {
  private analyzed: AnalyzedDependency[] = [];

  update(analyzed: AnalyzedDependency[]): void {
    this.analyzed = analyzed;
  }

  provideHover(document: vscode.TextDocument, position: vscode.Position): vscode.Hover | undefined {
    if (!getManifestType(document.uri.fsPath)) return undefined;

    const dep = this.analyzed.find(
      (a) =>
        a.manifestPath === document.uri.fsPath &&
        a.dep.line === position.line &&
        position.character >= a.dep.startChar &&
        position.character <= a.dep.endChar
    );
    if (!dep) return undefined;

    const md = new vscode.MarkdownString();
    md.isTrusted = false;
    md.supportHtml = false;
    md.appendMarkdown(`### LowEndInsight: ${text(dep.dep.name)}\n\n`);

    const range = new vscode.Range(dep.dep.line, dep.dep.startChar, dep.dep.line, dep.dep.endChar);
    const data = dep.report?.data;

    if (dep.coverage !== "analysed" || !data) {
      md.appendMarkdown(`**Not analysed:** ${text(dep.note ?? dep.coverage)}\n`);
      return new vscode.Hover(md, range);
    }

    const results = data.results ?? ({} as Partial<typeof data.results>);
    const risk = (r: RiskLevel | undefined) => (r ? `${RISK_EMOJI[r]} ${r}` : "not determined");

    md.appendMarkdown(`**Overall Risk:** \`${text(dep.risk).toUpperCase()}\`\n\n`);
    if (data.repo) md.appendMarkdown(`**Repository:** ${text(data.repo)}\n\n`);

    md.appendMarkdown("| Metric | Value | Risk |\n");
    md.appendMarkdown("|--------|-------|------|\n");
    md.appendMarkdown(`| Contributors | ${text(results.contributor_count)} | ${risk(results.contributor_risk)} |\n`);
    md.appendMarkdown(
      `| Functional Contributors | ${text(results.functional_contributors)} | ${risk(results.functional_contributors_risk)} |\n`
    );
    md.appendMarkdown(
      `| Commit Currency | ${text(results.commit_currency_weeks)} weeks | ${risk(results.commit_currency_risk)} |\n`
    );
    const pct = results.recent_commit_size_in_percent_of_codebase;
    md.appendMarkdown(
      `| Large Commit | ${typeof pct === "number" ? (pct * 100).toFixed(1) + "%" : "unknown"} | ${risk(results.large_recent_commit_risk)} |\n`
    );

    if (results.functional_contributor_names?.length) {
      md.appendMarkdown(`\n**Key Contributors:** ${results.functional_contributor_names.map(text).join(", ")}\n`);
    }
    if (dep.report?.header?.library_version) {
      md.appendMarkdown(`\n*Analyzed by LEI v${text(dep.report.header.library_version)}*`);
    }

    return new vscode.Hover(md, range);
  }

  dispose(): void {}
}
