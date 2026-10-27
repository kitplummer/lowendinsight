// Joins what the manifests declare to what the API answered. Pure, so
// src/test/assemble.test.ts covers it: this is where a dependency used to
// disappear when it had no result.
import { BatchResult, Coordinate, coordinateKey, ecosystemFor } from "./api";
import { tryResolveGitUrl } from "./manifestParser";
import { AnalyzedDependency, ManifestDependency, ParsedManifest, RepoReport, RiskLevel } from "./types";

const RISKS: RiskLevel[] = ["critical", "high", "medium", "low"];

/** How each declared dependency will be asked about. */
export type Plan =
  | { kind: "url"; url: string }
  | { kind: "batch"; coordinate: Coordinate }
  | { kind: "unsupported"; note: string };

export function plan(dep: ManifestDependency, manifest: ParsedManifest): Plan {
  const url = tryResolveGitUrl(dep, manifest.type);
  if (url) return { kind: "url", url };

  const ecosystem = ecosystemFor(manifest.type);
  if (!ecosystem) {
    return { kind: "unsupported", note: `${manifest.type} dependencies are not supported yet` };
  }
  // The service keys its cache on the version string; a manifest range is
  // fine, and a dependency with none is asked about as "*".
  return { kind: "batch", coordinate: { ecosystem, package: dep.name, version: dep.version || "*" } };
}

export function assemble(
  manifests: ParsedManifest[],
  batch: Map<string, BatchResult>,
  byUrl: Map<string, RepoReport>
): AnalyzedDependency[] {
  return manifests.flatMap((m) =>
    m.dependencies.map((dep): AnalyzedDependency => {
      const base = { dep, manifestPath: m.filePath };
      const p = plan(dep, m);

      switch (p.kind) {
        case "unsupported":
          return { ...base, coverage: "unsupported", note: p.note };

        case "url": {
          const report = byUrl.get(p.url);
          return report
            ? { ...base, coverage: "analysed", repoUrl: p.url, report, risk: riskOf(report.data?.risk) }
            : { ...base, coverage: "failed", repoUrl: p.url, note: "no report came back for this repository" };
        }

        case "batch": {
          const r = batch.get(coordinateKey(p.coordinate));
          if (!r) return { ...base, coverage: "failed", note: "no answer came back for this dependency" };

          switch (r.status) {
            case "cached": {
              const risk = riskOf(r.risk ?? r.analysis?.data?.risk);
              return risk
                ? { ...base, coverage: "analysed", report: r.analysis, risk, repoUrl: r.analysis?.data?.repo }
                : { ...base, coverage: "failed", note: "analysed, but no risk was determined" };
            }
            case "pending":
              return { ...base, coverage: "pending", note: "still being analysed; run LEI: Analyze again shortly" };
            case "uncached":
              return { ...base, coverage: "failed", note: "the service could not queue it" };
            case "failed":
              return { ...base, coverage: "failed", note: describe(r.error) };
            default:
              return { ...base, coverage: "failed", note: `unexpected status: ${r.status}` };
          }
        }
      }
    })
  );
}

function riskOf(value: unknown): RiskLevel | undefined {
  return RISKS.find((r) => r === value);
}

// The service reports the reason as an inspected Elixir term.
function describe(error: string | undefined): string {
  if (!error) return "the analysis failed";
  if (error.includes("no_repository")) return "its registry entry names no source repository";
  if (error.includes("not_found")) return "not found in its registry";
  if (error.includes("unsupported_ecosystem")) return "this ecosystem is not supported by the service";
  return `the analysis failed: ${error}`;
}
