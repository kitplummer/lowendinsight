import * as vscode from "vscode";
import { AnalyzedDependency, RiskLevel } from "./types";

const RISK_SEVERITY: Record<RiskLevel, vscode.DiagnosticSeverity> = {
  critical: vscode.DiagnosticSeverity.Error,
  high: vscode.DiagnosticSeverity.Warning,
  medium: vscode.DiagnosticSeverity.Information,
  low: vscode.DiagnosticSeverity.Hint,
};

const RISK_LABELS: Record<RiskLevel, string> = {
  critical: "CRITICAL",
  high: "HIGH",
  medium: "MEDIUM",
  low: "LOW",
};

export class LeiDiagnostics {
  private collection: vscode.DiagnosticCollection;

  constructor() {
    this.collection =
      vscode.languages.createDiagnosticCollection("lowendinsight");
  }

  update(analyzed: AnalyzedDependency[]): void {
    this.collection.clear();

    // Group by file
    const byFile = new Map<string, AnalyzedDependency[]>();
    for (const a of analyzed) {
      const existing = byFile.get(a.manifestPath) ?? [];
      existing.push(a);
      byFile.set(a.manifestPath, existing);
    }

    for (const [filePath, deps] of byFile) {
      const uri = vscode.Uri.file(filePath);
      const diagnostics: vscode.Diagnostic[] = [];

      for (const dep of deps) {
        if (!dep.risk || dep.risk === "low") continue;

        const range = new vscode.Range(
          dep.dep.line,
          dep.dep.startChar,
          dep.dep.line,
          dep.dep.endChar
        );

        const severity = RISK_SEVERITY[dep.risk];
        const label = RISK_LABELS[dep.risk];
        const results = dep.report?.data.results;

        let message = `[LEI ${label}] ${dep.dep.name}: overall risk is ${dep.risk}`;
        if (results) {
          message += `\n  Contributors: ${results.contributor_count} (${results.contributor_risk} risk)`;
          message += `\n  Functional contributors: ${results.functional_contributors} (${results.functional_contributors_risk} risk)`;
          message += `\n  Last commit: ${results.commit_currency_weeks} weeks ago (${results.commit_currency_risk} risk)`;
        }

        const diag = new vscode.Diagnostic(range, message, severity);
        diag.source = "LowEndInsight";
        diag.code = dep.repoUrl;
        diagnostics.push(diag);
      }

      if (diagnostics.length > 0) {
        this.collection.set(uri, diagnostics);
      }
    }
  }

  clear(): void {
    this.collection.clear();
  }

  dispose(): void {
    this.collection.dispose();
  }
}
