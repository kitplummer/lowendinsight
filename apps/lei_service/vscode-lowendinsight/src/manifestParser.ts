// Pure: no VS Code import, so src/test/manifestParser.test.ts can run it.
import {
  ManifestDependency,
  ManifestType,
  ParsedManifest,
} from "./types";

export const MANIFEST_GLOBS: Record<ManifestType, string> = {
  npm: "**/package.json",
  mix: "**/mix.exs",
  cargo: "**/Cargo.toml",
  go: "**/go.mod",
  pip: "**/requirements.txt",
  gem: "**/Gemfile",
  maven: "**/pom.xml",
  gradle: "**/build.gradle",
};

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

/** The dependencies a manifest of `type` declares, with their positions. */
export function parseManifestText(type: ManifestType, text: string): ManifestDependency[] {

  switch (type) {
    case "npm":
      return parseNpm(text);
    case "mix":
      return parseMix(text);
    case "cargo":
      return parseCargo(text);
    case "go":
      return parseGo(text);
    case "pip":
      return parsePip(text);
    case "gem":
      return parseGem(text);
    default:
      return [];
  }
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
 * The repository a dependency names directly, if it does: a git URL in the
 * manifest, or a Go module path on GitHub. Everything else goes to the
 * service by package name, which asks the registry.
 *
 * This used to guess `github.com/org/pkg` for an npm `@org/pkg`, so
 * `@types/node` became github.com/types/node, which does not exist.
 */
export function tryResolveGitUrl(
  dep: ManifestDependency,
  type: ManifestType
): string | undefined {
  if (dep.gitUrl) return dep.gitUrl;
  if (type === "go" && dep.name.startsWith("github.com/")) return `https://${dep.name}`;
  return undefined;
}
