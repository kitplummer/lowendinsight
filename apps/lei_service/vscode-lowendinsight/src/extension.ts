import * as vscode from "vscode";
import { LeiDiagnostics } from "./diagnostics";
import { LeiTreeProvider } from "./treeView";
import { LeiStatusBar } from "./statusBar";
import { LeiHoverProvider } from "./hoverProvider";
import { findManifests, parseManifest, tryResolveGitUrl } from "./manifestParser";
import { analyzeUrls } from "./leiClient";
import {
  AnalyzedDependency,
  ManifestDependency,
  ParsedManifest,
  RepoReport,
} from "./types";

let diagnostics: LeiDiagnostics;
let treeProvider: LeiTreeProvider;
let statusBar: LeiStatusBar;
let hoverProvider: LeiHoverProvider;
let analysisResults: AnalyzedDependency[] = [];
let debounceTimer: ReturnType<typeof setTimeout> | undefined;

export function activate(context: vscode.ExtensionContext): void {
  diagnostics = new LeiDiagnostics();
  treeProvider = new LeiTreeProvider();
  statusBar = new LeiStatusBar();
  hoverProvider = new LeiHoverProvider();

  // Register tree view
  const treeView = vscode.window.createTreeView("lowendinsight.riskView", {
    treeDataProvider: treeProvider,
    showCollapseAll: true,
  });

  // Register hover provider for all manifest file types
  const manifestSelectors: vscode.DocumentSelector = [
    { pattern: "**/package.json" },
    { pattern: "**/mix.exs" },
    { pattern: "**/Cargo.toml" },
    { pattern: "**/go.mod" },
    { pattern: "**/requirements.txt" },
    { pattern: "**/Gemfile" },
    { pattern: "**/pom.xml" },
    { pattern: "**/build.gradle" },
  ];

  const hoverDisposable = vscode.languages.registerHoverProvider(
    manifestSelectors,
    hoverProvider
  );

  // Register commands
  const analyzeCmd = vscode.commands.registerCommand(
    "lowendinsight.analyze",
    () => runAnalysis()
  );

  const analyzeFileCmd = vscode.commands.registerCommand(
    "lowendinsight.analyzeFile",
    () => {
      const editor = vscode.window.activeTextEditor;
      if (editor) {
        runAnalysis([editor.document.uri]);
      }
    }
  );

  const clearCmd = vscode.commands.registerCommand(
    "lowendinsight.clearDiagnostics",
    () => {
      diagnostics.clear();
      analysisResults = [];
      treeProvider.update([]);
      hoverProvider.update([]);
      statusBar.update([]);
    }
  );

  // FileSystemWatcher for manifest changes
  const watcher = vscode.workspace.createFileSystemWatcher(
    "**/{package.json,mix.exs,Cargo.toml,go.mod,requirements.txt,Gemfile,pom.xml,build.gradle}"
  );

  const onManifestChange = (uri: vscode.Uri) => {
    const cfg = vscode.workspace.getConfiguration("lowendinsight");
    if (!cfg.get<boolean>("autoAnalyze", true)) return;

    // Debounce to avoid rapid re-analysis
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => runAnalysis([uri]), 2000);
  };

  watcher.onDidChange(onManifestChange);
  watcher.onDidCreate(onManifestChange);
  watcher.onDidDelete(() => {
    // Re-run full analysis when a manifest is deleted
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => runAnalysis(), 2000);
  });

  context.subscriptions.push(
    diagnostics,
    treeView,
    treeProvider,
    hoverDisposable,
    analyzeCmd,
    analyzeFileCmd,
    clearCmd,
    watcher,
    statusBar
  );

  // Auto-analyze on activation
  const cfg = vscode.workspace.getConfiguration("lowendinsight");
  if (cfg.get<boolean>("autoAnalyze", true)) {
    runAnalysis();
  }
}

async function runAnalysis(uris?: vscode.Uri[]): Promise<void> {
  statusBar.showAnalyzing();

  try {
    // Find and parse manifests
    const manifestUris = uris ?? (await findManifests());
    const manifests: ParsedManifest[] = [];

    for (const uri of manifestUris) {
      const parsed = await parseManifest(uri);
      if (parsed && parsed.dependencies.length > 0) {
        manifests.push(parsed);
      }
    }

    if (manifests.length === 0) {
      statusBar.update([]);
      return;
    }

    // Collect all unique git URLs to analyze
    const urlToDeps = new Map<string, { dep: ManifestDependency; manifestPath: string }[]>();

    for (const manifest of manifests) {
      for (const dep of manifest.dependencies) {
        const gitUrl = tryResolveGitUrl(dep, manifest.type);
        if (gitUrl) {
          const existing = urlToDeps.get(gitUrl) ?? [];
          existing.push({ dep, manifestPath: manifest.filePath });
          urlToDeps.set(gitUrl, existing);
        }
      }
    }

    const urls = [...urlToDeps.keys()];

    if (urls.length === 0) {
      // No resolvable git URLs, show deps without analysis
      analysisResults = manifests.flatMap((m) =>
        m.dependencies.map((dep) => ({
          dep,
          manifestPath: m.filePath,
        }))
      );
      diagnostics.update(analysisResults);
      treeProvider.update(analysisResults);
      hoverProvider.update(analysisResults);
      statusBar.update(analysisResults);
      return;
    }

    // Call LEI API in batches of 10
    const batchSize = 10;
    const repoReports = new Map<string, RepoReport>();

    for (let i = 0; i < urls.length; i += batchSize) {
      const batch = urls.slice(i, i + batchSize);
      try {
        const report = await analyzeUrls(batch);
        if (report.report?.repos) {
          for (const repo of report.report.repos) {
            repoReports.set(repo.data.repo, repo);
          }
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        vscode.window.showWarningMessage(
          `LEI analysis batch failed: ${msg}`
        );
      }
    }

    // Map results back to dependencies
    analysisResults = [];

    for (const [url, deps] of urlToDeps) {
      const report = repoReports.get(url);
      for (const { dep, manifestPath } of deps) {
        analysisResults.push({
          dep,
          manifestPath,
          repoUrl: url,
          report,
          risk: report?.data.risk,
        });
      }
    }

    // Also include deps without resolved URLs (no risk data)
    for (const manifest of manifests) {
      for (const dep of manifest.dependencies) {
        const gitUrl = tryResolveGitUrl(dep, manifest.type);
        if (!gitUrl) {
          analysisResults.push({ dep, manifestPath: manifest.filePath });
        }
      }
    }

    diagnostics.update(analysisResults);
    treeProvider.update(analysisResults);
    hoverProvider.update(analysisResults);
    statusBar.update(analysisResults);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    statusBar.showError(msg);
    vscode.window.showErrorMessage(`LowEndInsight analysis failed: ${msg}`);
  }
}

export function deactivate(): void {
  if (debounceTimer) clearTimeout(debounceTimer);
}
