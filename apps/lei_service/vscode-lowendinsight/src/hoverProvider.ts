import * as vscode from "vscode";
import { AnalyzedDependency, RiskLevel } from "./types";
import { getManifestType } from "./manifestParser";

const RISK_EMOJI: Record<RiskLevel, string> = {
  critical: "!!",
  high: "! ",
  medium: "~ ",
  low: "ok",
};

export class LeiHoverProvider implements vscode.HoverProvider {
  private analyzed: AnalyzedDependency[] = [];

  update(analyzed: AnalyzedDependency[]): void {
    this.analyzed = analyzed;
  }

  provideHover(
    document: vscode.TextDocument,
    position: vscode.Position
  ): vscode.Hover | undefined {
    // Only provide hovers for manifest files
    if (!getManifestType(document.uri.fsPath)) return undefined;

    // Find matching dependency at this position
    const dep = this.analyzed.find(
      (a) =>
        a.manifestPath === document.uri.fsPath &&
        a.dep.line === position.line &&
        position.character >= a.dep.startChar &&
        position.character <= a.dep.endChar
    );

    if (!dep || !dep.report) return undefined;

    const data = dep.report.data;
    const results = data.results;
    const md = new vscode.MarkdownString();
    md.isTrusted = true;

    md.appendMarkdown(
      `### LowEndInsight: ${dep.dep.name}\n\n`
    );
    md.appendMarkdown(
      `**Overall Risk:** \`${data.risk.toUpperCase()}\`\n\n`
    );

    if (data.repo) {
      md.appendMarkdown(`**Repository:** ${data.repo}\n\n`);
    }

    md.appendMarkdown("| Metric | Value | Risk |\n");
    md.appendMarkdown("|--------|-------|------|\n");
    md.appendMarkdown(
      `| Contributors | ${results.contributor_count} | ${RISK_EMOJI[results.contributor_risk]} ${results.contributor_risk} |\n`
    );
    md.appendMarkdown(
      `| Functional Contributors | ${results.functional_contributors} | ${RISK_EMOJI[results.functional_contributors_risk]} ${results.functional_contributors_risk} |\n`
    );
    md.appendMarkdown(
      `| Commit Currency | ${results.commit_currency_weeks} weeks | ${RISK_EMOJI[results.commit_currency_risk]} ${results.commit_currency_risk} |\n`
    );
    md.appendMarkdown(
      `| Large Commit | ${(results.recent_commit_size_in_percent_of_codebase * 100).toFixed(1)}% | ${RISK_EMOJI[results.large_recent_commit_risk]} ${results.large_recent_commit_risk} |\n`
    );

    if (
      results.functional_contributor_names &&
      results.functional_contributor_names.length > 0
    ) {
      md.appendMarkdown(
        `\n**Key Contributors:** ${results.functional_contributor_names.join(", ")}\n`
      );
    }

    md.appendMarkdown(
      `\n*Analyzed by LEI v${dep.report.header.library_version}*`
    );

    const range = new vscode.Range(
      dep.dep.line,
      dep.dep.startChar,
      dep.dep.line,
      dep.dep.endChar
    );

    return new vscode.Hover(md, range);
  }

  dispose(): void {}
}
