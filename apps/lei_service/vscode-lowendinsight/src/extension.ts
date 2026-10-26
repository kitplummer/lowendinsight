import * as vscode from "vscode";
import { LeiDiagnostics } from "./diagnostics";
import { LeiTreeProvider } from "./treeView";
import { LeiStatusBar } from "./statusBar";
import { LeiHoverProvider } from "./hoverProvider";
import { findManifests, parseManifest } from "./workspace";
import { analyzeBatch, analyzeUrls, ApiConfig, Coordinate, LeiApiError, SIGNUP_URL } from "./api";
import { assemble, plan } from "./assemble";
import { ParsedManifest } from "./types";

// The key lives in VS Code's secret storage, not settings.json: settings are
// plain text and Settings Sync copies them between machines.
const KEY_SECRET = "lowendinsight.apiKey";

let context: vscode.ExtensionContext;
let diagnostics: LeiDiagnostics;
let treeProvider: LeiTreeProvider;
let statusBar: LeiStatusBar;
let hoverProvider: LeiHoverProvider;
let debounceTimer: ReturnType<typeof setTimeout> | undefined;
let running = false;

export async function activate(ctx: vscode.ExtensionContext): Promise<void> {
  context = ctx;
  diagnostics = new LeiDiagnostics();
  treeProvider = new LeiTreeProvider();
  statusBar = new LeiStatusBar();
  hoverProvider = new LeiHoverProvider();

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

  const watcher = vscode.workspace.createFileSystemWatcher(
    "**/{package.json,mix.exs,Cargo.toml,go.mod,requirements.txt,Gemfile,pom.xml,build.gradle}"
  );
  const onManifestChange = (uri?: vscode.Uri) => {
    if (!vscode.workspace.getConfiguration("lowendinsight").get<boolean>("autoAnalyze", true)) return;
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => runAnalysis(uri ? [uri] : undefined, { quiet: true }), 2000);
  };
  watcher.onDidChange(onManifestChange);
  watcher.onDidCreate(onManifestChange);
  watcher.onDidDelete(() => onManifestChange());

  ctx.subscriptions.push(
    diagnostics,
    vscode.window.createTreeView("lowendinsight.riskView", {
      treeDataProvider: treeProvider,
      showCollapseAll: true,
    }),
    treeProvider,
    vscode.languages.registerHoverProvider(manifestSelectors, hoverProvider),
    vscode.commands.registerCommand("lowendinsight.analyze", () => runAnalysis()),
    vscode.commands.registerCommand("lowendinsight.analyzeFile", () => {
      const editor = vscode.window.activeTextEditor;
      if (editor) runAnalysis([editor.document.uri]);
    }),
    vscode.commands.registerCommand("lowendinsight.clearDiagnostics", () => show([])),
    vscode.commands.registerCommand("lowendinsight.setApiKey", setApiKey),
    vscode.commands.registerCommand("lowendinsight.getApiKey", () =>
      vscode.env.openExternal(vscode.Uri.parse(SIGNUP_URL))
    ),
    watcher,
    statusBar
  );

  // Nothing leaves the machine until a key is set: without one the request
  // would be refused anyway, and the dependency list would have been sent to a
  // third party by opening a folder.
  if (await apiKey()) {
    if (vscode.workspace.getConfiguration("lowendinsight").get<boolean>("autoAnalyze", true)) {
      runAnalysis(undefined, { quiet: true });
    }
  } else {
    statusBar.showNoKey();
  }
}

async function apiKey(): Promise<string> {
  return (await context.secrets.get(KEY_SECRET)) ?? "";
}

async function config(): Promise<ApiConfig> {
  return {
    apiUrl: vscode.workspace
      .getConfiguration("lowendinsight")
      .get<string>("apiUrl", "https://lowendinsight.dev"),
    apiKey: await apiKey(),
  };
}

async function setApiKey(): Promise<void> {
  const key = await vscode.window.showInputBox({
    title: "LowEndInsight API key",
    prompt: `Paste your API key (lei_…). No key yet? Get one free during the beta at ${SIGNUP_URL}`,
    password: true,
    ignoreFocusOut: true,
    validateInput: (v) => (v.trim() === "" || v.trim().startsWith("lei_") ? undefined : "API keys start with lei_"),
  });
  if (key === undefined) return;

  if (key.trim() === "") {
    await context.secrets.delete(KEY_SECRET);
    statusBar.showNoKey();
    return;
  }
  await context.secrets.store(KEY_SECRET, key.trim());
  runAnalysis();
}

async function runAnalysis(uris?: vscode.Uri[], opts: { quiet?: boolean } = {}): Promise<void> {
  if (running) return;
  running = true;
  statusBar.showAnalyzing();

  try {
    const manifests: ParsedManifest[] = [];
    for (const uri of uris ?? (await findManifests())) {
      const parsed = await parseManifest(uri);
      if (parsed && parsed.dependencies.length > 0) manifests.push(parsed);
    }

    const urls = new Set<string>();
    const coordinates: Coordinate[] = [];
    for (const m of manifests) {
      for (const dep of m.dependencies) {
        const p = plan(dep, m);
        if (p.kind === "url") urls.add(p.url);
        if (p.kind === "batch") coordinates.push(p.coordinate);
      }
    }

    const cfg = await config();
    const [batch, byUrl] = await Promise.all([
      analyzeBatch(cfg, coordinates),
      analyzeUrls(cfg, [...urls]),
    ]);
    show(assemble(manifests, batch, byUrl));
  } catch (err) {
    reportError(err, opts.quiet ?? false);
  } finally {
    running = false;
  }
}

function show(analyzed: ReturnType<typeof assemble>): void {
  diagnostics.update(analyzed);
  treeProvider.update(analyzed);
  hoverProvider.update(analyzed);
  statusBar.update(analyzed);
}

async function reportError(err: unknown, quiet: boolean): Promise<void> {
  const msg = err instanceof Error ? err.message : String(err);
  const kind = err instanceof LeiApiError ? err.kind : undefined;

  if (kind === "no-key" || kind === "invalid-key" || kind === "forbidden" || kind === "payment-required") {
    statusBar.showNoKey(msg);
    if (quiet && kind === "no-key") return;
    const choice = await vscode.window.showWarningMessage(msg, "Set API key", "Get a free key");
    if (choice === "Set API key") vscode.commands.executeCommand("lowendinsight.setApiKey");
    if (choice === "Get a free key") vscode.commands.executeCommand("lowendinsight.getApiKey");
    return;
  }

  statusBar.showError(msg);
  if (!quiet) vscode.window.showErrorMessage(`LowEndInsight: ${msg}`);
}

export function deactivate(): void {
  if (debounceTimer) clearTimeout(debounceTimer);
}
