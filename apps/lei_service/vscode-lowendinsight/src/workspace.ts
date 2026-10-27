import * as vscode from "vscode";
import { getManifestType, MANIFEST_GLOBS, parseManifestText } from "./manifestParser";
import { ParsedManifest } from "./types";

export async function findManifests(): Promise<vscode.Uri[]> {
  const uris: vscode.Uri[] = [];
  for (const glob of Object.values(MANIFEST_GLOBS)) {
    uris.push(...(await vscode.workspace.findFiles(glob, "**/node_modules/**")));
  }
  return uris;
}

export async function parseManifest(uri: vscode.Uri): Promise<ParsedManifest | undefined> {
  const type = getManifestType(uri.fsPath);
  if (!type) return undefined;
  const doc = await vscode.workspace.openTextDocument(uri);
  return { filePath: uri.fsPath, type, dependencies: parseManifestText(type, doc.getText()) };
}
