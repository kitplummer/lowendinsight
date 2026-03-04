import * as vscode from "vscode";
import { AnalyzedDependency, RiskLevel } from "./types";

const RISK_PRIORITY: Record<RiskLevel, number> = {
  critical: 3,
  high: 2,
  medium: 1,
  low: 0,
};

export class LeiStatusBar {
  private item: vscode.StatusBarItem;

  constructor() {
    this.item = vscode.window.createStatusBarItem(
      vscode.StatusBarAlignment.Left,
      50
    );
    this.item.command = "lowendinsight.analyze";
    this.item.tooltip = "LowEndInsight: Click to analyze dependencies";
    this.item.text = "$(shield) LEI";
    this.item.show();
  }

  update(analyzed: AnalyzedDependency[]): void {
    if (analyzed.length === 0) {
      this.item.text = "$(shield) LEI: No deps";
      this.item.backgroundColor = undefined;
      return;
    }

    const counts: Record<RiskLevel, number> = {
      critical: 0,
      high: 0,
      medium: 0,
      low: 0,
    };

    for (const dep of analyzed) {
      if (dep.risk) {
        counts[dep.risk]++;
      }
    }

    // Determine worst risk level
    let worstRisk: RiskLevel = "low";
    for (const risk of Object.keys(RISK_PRIORITY) as RiskLevel[]) {
      if (counts[risk] > 0 && RISK_PRIORITY[risk] > RISK_PRIORITY[worstRisk]) {
        worstRisk = risk;
      }
    }

    const parts: string[] = [];
    if (counts.critical) parts.push(`${counts.critical}C`);
    if (counts.high) parts.push(`${counts.high}H`);
    if (counts.medium) parts.push(`${counts.medium}M`);
    if (counts.low) parts.push(`${counts.low}L`);

    this.item.text = `$(shield) LEI: ${parts.join(" ")}`;

    if (worstRisk === "critical") {
      this.item.backgroundColor = new vscode.ThemeColor(
        "statusBarItem.errorBackground"
      );
    } else if (worstRisk === "high") {
      this.item.backgroundColor = new vscode.ThemeColor(
        "statusBarItem.warningBackground"
      );
    } else {
      this.item.backgroundColor = undefined;
    }

    this.item.tooltip = `LowEndInsight: ${analyzed.length} deps analyzed\nCritical: ${counts.critical} | High: ${counts.high} | Medium: ${counts.medium} | Low: ${counts.low}`;
  }

  showAnalyzing(): void {
    this.item.text = "$(loading~spin) LEI: Analyzing...";
    this.item.backgroundColor = undefined;
  }

  showError(msg: string): void {
    this.item.text = "$(shield) LEI: Error";
    this.item.tooltip = `LowEndInsight Error: ${msg}`;
    this.item.backgroundColor = new vscode.ThemeColor(
      "statusBarItem.errorBackground"
    );
  }

  dispose(): void {
    this.item.dispose();
  }
}
