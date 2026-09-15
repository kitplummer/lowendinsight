import * as vscode from "vscode";
import { AnalyzedDependency, RiskLevel } from "./types";

const RISK_ORDER: RiskLevel[] = ["critical", "high", "medium", "low"];

const RISK_ICONS: Record<RiskLevel, vscode.ThemeIcon> = {
  critical: new vscode.ThemeIcon("error", new vscode.ThemeColor("errorForeground")),
  high: new vscode.ThemeIcon("warning", new vscode.ThemeColor("editorWarning.foreground")),
  medium: new vscode.ThemeIcon("info", new vscode.ThemeColor("editorInfo.foreground")),
  low: new vscode.ThemeIcon("pass", new vscode.ThemeColor("testing.iconPassed")),
};

type TreeItem = RiskGroupItem | DepItem | DetailItem;

class RiskGroupItem extends vscode.TreeItem {
  constructor(
    public readonly risk: RiskLevel,
    public readonly deps: AnalyzedDependency[]
  ) {
    super(
      `${risk.toUpperCase()} (${deps.length})`,
      vscode.TreeItemCollapsibleState.Expanded
    );
    this.iconPath = RISK_ICONS[risk];
    this.contextValue = "riskGroup";
  }
}

class DepItem extends vscode.TreeItem {
  constructor(public readonly dep: AnalyzedDependency) {
    super(dep.dep.name, vscode.TreeItemCollapsibleState.Collapsed);
    this.iconPath = dep.risk ? RISK_ICONS[dep.risk] : undefined;
    this.description = dep.repoUrl
      ? dep.repoUrl.replace("https://github.com/", "")
      : dep.dep.version ?? "";
    this.contextValue = "dependency";

    if (dep.manifestPath) {
      this.command = {
        command: "vscode.open",
        title: "Go to dependency",
        arguments: [
          vscode.Uri.file(dep.manifestPath),
          {
            selection: new vscode.Range(
              dep.dep.line,
              dep.dep.startChar,
              dep.dep.line,
              dep.dep.endChar
            ),
          },
        ],
      };
    }
  }
}

class DetailItem extends vscode.TreeItem {
  constructor(label: string, detail: string) {
    super(label, vscode.TreeItemCollapsibleState.None);
    this.description = detail;
    this.contextValue = "detail";
  }
}

export class LeiTreeProvider
  implements vscode.TreeDataProvider<TreeItem>
{
  private _onDidChange = new vscode.EventEmitter<
    TreeItem | undefined | null | void
  >();
  readonly onDidChangeTreeData = this._onDidChange.event;

  private analyzed: AnalyzedDependency[] = [];

  update(analyzed: AnalyzedDependency[]): void {
    this.analyzed = analyzed;
    this._onDidChange.fire();
  }

  getTreeItem(element: TreeItem): vscode.TreeItem {
    return element;
  }

  getChildren(element?: TreeItem): TreeItem[] {
    if (!element) {
      // Root: group by risk level
      return RISK_ORDER.map((risk) => {
        const deps = this.analyzed.filter((a) => a.risk === risk);
        return new RiskGroupItem(risk, deps);
      }).filter((g) => g.deps.length > 0);
    }

    if (element instanceof RiskGroupItem) {
      return element.deps.map((d) => new DepItem(d));
    }

    if (element instanceof DepItem) {
      const results = element.dep.report?.data.results;
      if (!results) return [];

      const items: DetailItem[] = [
        new DetailItem(
          "Contributors",
          `${results.contributor_count} total, ${results.functional_contributors} functional`
        ),
        new DetailItem("Contributor Risk", results.contributor_risk),
        new DetailItem(
          "Functional Contributors Risk",
          results.functional_contributors_risk
        ),
        new DetailItem(
          "Commit Currency",
          `${results.commit_currency_weeks} weeks (${results.commit_currency_risk})`
        ),
        new DetailItem(
          "Large Commit Risk",
          `${results.large_recent_commit_risk} (${(results.recent_commit_size_in_percent_of_codebase * 100).toFixed(1)}%)`
        ),
      ];

      if (
        results.functional_contributor_names &&
        results.functional_contributor_names.length > 0
      ) {
        items.push(
          new DetailItem(
            "Key Contributors",
            results.functional_contributor_names.join(", ")
          )
        );
      }

      return items;
    }

    return [];
  }

  dispose(): void {
    this._onDidChange.dispose();
  }
}
