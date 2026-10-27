import { test } from "node:test";
import * as assert from "node:assert/strict";
import { assemble, plan } from "../assemble";
import { BatchResult } from "../api";
import { parseManifestText } from "../manifestParser";
import { ParsedManifest, RepoReport } from "../types";

const npm = (deps: Record<string, string>): ParsedManifest => ({
  filePath: "/w/package.json",
  type: "npm",
  dependencies: parseManifestText("npm", JSON.stringify({ dependencies: deps }, null, 2)),
});

const report = (repo: string, risk: string) =>
  ({ data: { repo, risk, results: {} }, header: {} }) as unknown as RepoReport;

const result = (pkg: string, r: Partial<BatchResult>): [string, BatchResult] => [
  `npm/${pkg}@^1.0.0`,
  { ecosystem: "npm", package: pkg, version: "^1.0.0", status: "cached", ...r },
];

test("an unscoped package is asked about by name, not skipped", () => {
  const m = npm({ lodash: "^4.17.21" });
  assert.deepEqual(plan(m.dependencies[0], m), {
    kind: "batch",
    coordinate: { ecosystem: "npm", package: "lodash", version: "^4.17.21" },
  });
});

test("a scoped package is not guessed onto GitHub", () => {
  const m = npm({ "@types/node": "^20.0.0" });
  const p = plan(m.dependencies[0], m);
  assert.equal(p.kind, "batch", "@types/node was resolved to a guessed URL");
});

test("a dependency that names its repository is asked about by URL", () => {
  const m = npm({ x: "git+https://github.com/o/x.git" });
  assert.equal(plan(m.dependencies[0], m).kind, "url");
});

test("every declared dependency is in the result, whatever happened to it", () => {
  const m = npm({ a: "^1.0.0", b: "^1.0.0", c: "^1.0.0", d: "^1.0.0", e: "^1.0.0" });
  const batch = new Map([
    result("a", { risk: "high", analysis: report("https://github.com/o/a", "high") }),
    result("b", { status: "pending" }),
    result("c", { status: "failed", error: ":no_repository" }),
    result("d", { status: "uncached" }),
    // e: no answer at all
  ]);

  const out = assemble([m], batch, new Map());
  const by = Object.fromEntries(out.map((a) => [a.dep.name, a]));

  assert.equal(out.length, 5);
  assert.equal(by.a.coverage, "analysed");
  assert.equal(by.a.risk, "high");
  assert.equal(by.b.coverage, "pending");
  assert.equal(by.c.coverage, "failed");
  assert.match(by.c.note!, /no source repository/);
  assert.equal(by.d.coverage, "failed");
  assert.equal(by.e.coverage, "failed");
  for (const name of ["b", "c", "d", "e"]) assert.ok(by[name].note, `${name} has no explanation`);
});

test("an analysis with no risk is not shown as analysed", () => {
  const m = npm({ a: "^1.0.0" });
  const [only] = assemble([m], new Map([result("a", { risk: undefined, analysis: undefined })]), new Map());
  assert.equal(only.coverage, "failed");
});

test("a manifest type the service does not resolve says so", () => {
  const m: ParsedManifest = {
    filePath: "/w/pom.xml",
    type: "maven",
    dependencies: [{ name: "junit", version: "4.13", line: 1, startChar: 0, endChar: 5 }],
  };
  const [only] = assemble([m], new Map(), new Map());
  assert.equal(only.coverage, "unsupported");
  assert.match(only.note!, /maven/);
});

test("mix dependencies go to hex", () => {
  const text = 'defp deps do\n  [\n    {:jason, "~> 1.4"}\n  ]\nend\n';
  const deps = parseManifestText("mix", text);
  const p = plan(deps[0], { filePath: "/w/mix.exs", type: "mix", dependencies: deps });
  assert.deepEqual(p, { kind: "batch", coordinate: { ecosystem: "hex", package: "jason", version: "~> 1.4" } });
});
