import * as vscode from "vscode";
import {
  ManifestDependency,
  ManifestType,
  ParsedManifest,
} from "./types";

const MANIFEST_GLOBS: Record<ManifestType, string> = {
  npm: "**/package.json",
  mix: "**/mix.exs",
  cargo: "**/Cargo.toml",
  go: "**/go.mod",
  pip: "**/requirements.txt",
  gem: "**/Gemfile",
  maven: "**/pom.xml",
  gradle: "**/build.gradle",
};

// GitHub URL patterns for resolving package names
const GITHUB_PREFIX = "https://github.com/";

export function getManifestType(fileName: string): ManifestType | undefined {
  const base = fileName.split("/").pop() ?? "";
  if (base === "package.json") return "npm";
  if (base === "mix.exs") return "mix";
  if (base === "Cargo.toml") return "cargo";
  if (base === "go.mod") return "go";
  if (base === "requirements.txt") return "pip";
  if (base === "Gemfile") return "gem";
  if (base === "pom.xml") return "maven";
  if (base === "build.gradle") return "gradle";
  return undefined;
}

export async function findManifests(): Promise<vscode.Uri[]> {
  const uris: vscode.Uri[] = [];
  for (const glob of Object.values(MANIFEST_GLOBS)) {
    const found = await vscode.workspace.findFiles(
      glob,
      "**/node_modules/**"
    );
    uris.push(...found);
  }
  return uris;
}

export async function parseManifest(
  uri: vscode.Uri
): Promise<ParsedManifest | undefined> {
  const type = getManifestType(uri.fsPath);
  if (!type) return undefined;

  const doc = await vscode.workspace.openTextDocument(uri);
  const text = doc.getText();

  let deps: ManifestDependency[];
  switch (type) {
    case "npm":
      deps = parseNpm(text);
      break;
    case "mix":
      deps = parseMix(text);
      break;
    case "cargo":
      deps = parseCargo(text);
      break;
    case "go":
      deps = parseGo(text);
      break;
    case "pip":
      deps = parsePip(text);
      break;
    case "gem":
      deps = parseGem(text);
      break;
    default:
      deps = [];
  }

  return { filePath: uri.fsPath, type, dependencies: deps };
}

function parseNpm(text: string): ManifestDependency[] {
  const deps: ManifestDependency[] = [];
  const lines = text.split("\n");

  let inDeps = false;
  let braceDepth = 0;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    if (
      /"(dependencies|devDependencies|peerDependencies|optionalDependencies)"/.test(
        line
      )
    ) {
      inDeps = true;
      braceDepth = 0;
      if (line.includes("{")) braceDepth++;
      continue;
    }

    if (inDeps) {
      if (line.includes("{")) braceDepth++;
      if (line.includes("}")) braceDepth--;
      if (braceDepth <= 0) {
        inDeps = false;
        continue;
      }

      const match = line.match(/^\s*"([^"]+)"\s*:\s*"([^"]*)"/);
      if (match) {
        const name = match[1];
        const version = match[2];
        const startChar = line.indexOf(`"${name}"`);
        const endChar = startChar + name.length + 2;

        // Check if version is a git URL
        let gitUrl: string | undefined;
        if (
          version.startsWith("git+") ||
          version.startsWith("git://") ||
          version.includes("github.com")
        ) {
          gitUrl = version.replace(/^git\+/, "").replace(/#.*$/, "");
        }

        deps.push({ name, version, gitUrl, line: i, startChar, endChar });
      }
    }
  }

  return deps;
}

function parseMix(text: string): ManifestDependency[] {
  const deps: ManifestDependency[] = [];
  const lines = text.split("\n");

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // Match {:dep_name, "~> 1.0"} or {:dep_name, git: "url"}
    const match = line.match(
      /\{:(\w+)\s*,\s*(?:"([^"]*)"|(git:\s*"([^"]*)"))/
    );
    if (match) {
      const name = match[1];
      const version = match[2];
      const gitUrl = match[4];
      const startChar = line.indexOf(`{:${name}`);
      const endChar = startChar + name.length + 3;

      deps.push({ name, version, gitUrl, line: i, startChar, endChar });
    }
  }

  return deps;
}

function parseCargo(text: string): ManifestDependency[] {
  const deps: ManifestDependency[] = [];
  const lines = text.split("\n");

  let inDeps = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    if (/^\[(.*dependencies.*)\]/.test(line)) {
      inDeps = true;
      continue;
    }
    if (/^\[/.test(line) && inDeps) {
      inDeps = false;
      continue;
    }

    if (inDeps) {
      // Simple: name = "version"
      let match = line.match(/^(\w[\w-]*)\s*=\s*"([^"]*)"/);
      if (match) {
        const name = match[1];
        const version = match[2];
        const startChar = line.indexOf(name);
        const endChar = startChar + name.length;
        deps.push({ name, version, line: i, startChar, endChar });
        continue;
      }

      // Table inline: name = { version = "x", git = "url" }
      match = line.match(/^(\w[\w-]*)\s*=\s*\{/);
      if (match) {
        const name = match[1];
        const gitMatch = line.match(/git\s*=\s*"([^"]*)"/);
        const verMatch = line.match(/version\s*=\s*"([^"]*)"/);
        const startChar = line.indexOf(name);
        const endChar = startChar + name.length;
        deps.push({
          name,
          version: verMatch?.[1],
          gitUrl: gitMatch?.[1],
          line: i,
          startChar,
          endChar,
        });
      }
    }
  }

  return deps;
}

function parseGo(text: string): ManifestDependency[] {
  const deps: ManifestDependency[] = [];
  const lines = text.split("\n");

  let inRequire = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();

    if (line === "require (") {
      inRequire = true;
      continue;
    }
    if (line === ")" && inRequire) {
      inRequire = false;
      continue;
    }

    if (inRequire) {
      const match = line.match(/^(\S+)\s+(\S+)/);
      if (match) {
        const name = match[1];
        const version = match[2];
        const startChar = lines[i].indexOf(name);
        const endChar = startChar + name.length;

        // Go modules use their URL as the name (e.g., github.com/foo/bar)
        let gitUrl: string | undefined;
        if (name.startsWith("github.com/")) {
          gitUrl = `https://${name}`;
        }

        deps.push({ name, version, gitUrl, line: i, startChar, endChar });
      }
    }
  }

  return deps;
}

function parsePip(text: string): ManifestDependency[] {
  const deps: ManifestDependency[] = [];
  const lines = text.split("\n");

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line || line.startsWith("#")) continue;

    // git+https://github.com/...
    if (line.startsWith("git+") || line.startsWith("-e git+")) {
      const urlMatch = line.match(
        /git\+(https?:\/\/[^@#\s]+)/
      );
      if (urlMatch) {
        const gitUrl = urlMatch[1];
        const name = gitUrl.split("/").pop()?.replace(/\.git$/, "") ?? line;
        deps.push({
          name,
          gitUrl,
          line: i,
          startChar: 0,
          endChar: line.length,
        });
      }
      continue;
    }

    // package==version or package>=version etc.
    const match = line.match(/^([a-zA-Z0-9_.-]+)\s*([><=!~]+\s*\S+)?/);
    if (match) {
      const name = match[1];
      const version = match[2]?.trim();
      deps.push({
        name,
        version,
        line: i,
        startChar: 0,
        endChar: name.length,
      });
    }
  }

  return deps;
}

function parseGem(text: string): ManifestDependency[] {
  const deps: ManifestDependency[] = [];
  const lines = text.split("\n");

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // gem 'name', '~> 1.0' or gem 'name', git: 'url'
    const match = line.match(
      /gem\s+['"]([^'"]+)['"]\s*(?:,\s*['"]([^'"]*)['"]\s*)?(?:,\s*git:\s*['"]([^'"]*)['"]\s*)?/
    );
    if (match) {
      const name = match[1];
      const version = match[2];
      const gitUrl = match[3];
      const startChar = line.indexOf(`'${name}'`) !== -1
        ? line.indexOf(`'${name}'`)
        : line.indexOf(`"${name}"`);
      const endChar = startChar + name.length + 2;

      deps.push({ name, version, gitUrl, line: i, startChar, endChar });
    }
  }

  return deps;
}

/**
 * Try to resolve a package name to a GitHub URL.
 * For packages that don't have explicit git URLs, we attempt
 * to look them up via common naming conventions.
 */
export function tryResolveGitUrl(
  dep: ManifestDependency,
  type: ManifestType
): string | undefined {
  if (dep.gitUrl) return dep.gitUrl;

  // Go modules already contain the URL
  if (type === "go" && dep.name.startsWith("github.com/")) {
    return `https://${dep.name}`;
  }

  // For npm scoped packages like @org/pkg, try github.com/org/pkg
  if (type === "npm" && dep.name.startsWith("@")) {
    const parts = dep.name.replace("@", "").split("/");
    if (parts.length === 2) {
      return `${GITHUB_PREFIX}${parts[0]}/${parts[1]}`;
    }
  }

  return undefined;
}
