import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as http from "node:http";
import { AddressInfo } from "node:net";
import { analyzeBatch, analyzeUrls, ecosystemFor, LeiApiError } from "../api";

interface Seen {
  path: string;
  auth?: string;
  body: any;
}

// A stub API on an OS-assigned port. `respond` gets the request number (from
// 1) and the parsed body, and returns [status, body].
async function stub(
  respond: (n: number, body: any) => [number, unknown]
): Promise<{ url: string; seen: Seen[]; close: () => void }> {
  const seen: Seen[] = [];
  const server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      const body = raw ? JSON.parse(raw) : undefined;
      seen.push({ path: req.url ?? "", auth: req.headers.authorization, body });
      const [status, out] = respond(seen.length, body);
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(typeof out === "string" ? out : JSON.stringify(out));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const { port } = server.address() as AddressInfo;
  return { url: `http://127.0.0.1:${port}`, seen, close: () => server.close() };
}

const dep = (pkg: string) => ({ ecosystem: "npm", package: pkg, version: "^1.0.0" });
const cached = (pkg: string, risk = "low") => ({
  ...dep(pkg),
  status: "cached",
  risk,
  analysis: { data: { repo: `https://github.com/o/${pkg}`, risk, results: {} }, header: {} },
});
const pending = (pkg: string) => ({ ...dep(pkg), status: "pending" });
const fast = { intervalMs: 1, maxWaitMs: 1000 };

test("sends the key as a bearer token, and the dependencies by name", async () => {
  const api = await stub(() => [200, { results: [cached("a")] }]);
  try {
    await analyzeBatch({ apiUrl: api.url, apiKey: "lei_k" }, [dep("a")], fast);
    assert.equal(api.seen[0].path, "/v1/analyze/batch");
    assert.equal(api.seen[0].auth, "Bearer lei_k");
    assert.deepEqual(api.seen[0].body.dependencies, [dep("a")]);
  } finally {
    api.close();
  }
});

test("re-asks only for what is still pending, until it is done", async () => {
  const api = await stub((n, body) =>
    n === 1
      ? [200, { results: [cached("a"), pending("b")] }]
      : n === 2
        ? [200, { results: [pending("b")] }]
        : [200, { results: [cached("b", "high")] }]
  );
  try {
    const out = await analyzeBatch({ apiUrl: api.url, apiKey: "k" }, [dep("a"), dep("b")], fast);

    assert.equal(api.seen.length, 3);
    // A re-ask that included "a" would be priced again for an answer it has.
    assert.deepEqual(api.seen[1].body.dependencies, [dep("b")]);
    assert.deepEqual(api.seen[2].body.dependencies, [dep("b")]);
    assert.equal(out.get("npm/b@^1.0.0")?.risk, "high");
    assert.equal(out.get("npm/a@^1.0.0")?.status, "cached");
  } finally {
    api.close();
  }
});

test("stops waiting at the deadline and reports pending as pending", async () => {
  const api = await stub(() => [200, { results: [pending("b")] }]);
  try {
    const out = await analyzeBatch({ apiUrl: api.url, apiKey: "k" }, [dep("b")], {
      intervalMs: 5,
      maxWaitMs: 30,
    });
    assert.equal(out.get("npm/b@^1.0.0")?.status, "pending");
  } finally {
    api.close();
  }
});

test("a failed dependency carries the service's reason", async () => {
  const api = await stub(() => [
    200,
    { results: [{ ...dep("gone"), status: "failed", error: ":no_repository" }] },
  ]);
  try {
    const out = await analyzeBatch({ apiUrl: api.url, apiKey: "k" }, [dep("gone")], fast);
    assert.equal(out.get("npm/gone@^1.0.0")?.error, ":no_repository");
  } finally {
    api.close();
  }
});

test("splits more than 500 dependencies across requests", async () => {
  const api = await stub((_n, body) => [
    200,
    { results: body.dependencies.map((d: any) => cached(d.package)) },
  ]);
  try {
    const deps = Array.from({ length: 1201 }, (_, i) => dep(`p${i}`));
    const out = await analyzeBatch({ apiUrl: api.url, apiKey: "k" }, deps, fast);
    assert.deepEqual(
      api.seen.map((s) => s.body.dependencies.length),
      [500, 500, 201]
    );
    assert.equal(out.size, 1201);
  } finally {
    api.close();
  }
});

const kindOf = async (p: Promise<unknown>) => {
  try {
    await p;
  } catch (err) {
    assert.ok(err instanceof LeiApiError, `not a LeiApiError: ${err}`);
    return err.kind;
  }
  assert.fail("did not throw");
};

for (const [status, kind] of [
  [401, "invalid-key"],
  [403, "forbidden"],
  [402, "payment-required"],
  [429, "rate-limited"],
  [422, "rejected"],
  [500, "unavailable"],
] as const) {
  test(`HTTP ${status} is reported as ${kind}`, async () => {
    const api = await stub(() => [status, { error: "nope" }]);
    try {
      assert.equal(await kindOf(analyzeBatch({ apiUrl: api.url, apiKey: "k" }, [dep("a")], fast)), kind);
    } finally {
      api.close();
    }
  });
}

test("a payment challenge points a person at a free key, not a wallet", async () => {
  const api = await stub(() => [402, { error: "payment required" }]);
  try {
    await assert.rejects(
      analyzeBatch({ apiUrl: api.url, apiKey: "k" }, [dep("a")], fast),
      /lowendinsight\.dev\/signup/
    );
  } finally {
    api.close();
  }
});

test("with no key, nothing is sent", async () => {
  const api = await stub(() => [200, { results: [] }]);
  try {
    assert.equal(await kindOf(analyzeBatch({ apiUrl: api.url, apiKey: "" }, [dep("a")], fast)), "no-key");
    assert.equal(api.seen.length, 0, "the dependency list left the machine without a key");
  } finally {
    api.close();
  }
});

test("an unreachable server is unavailable, not a crash", async () => {
  assert.equal(
    await kindOf(analyzeBatch({ apiUrl: "http://127.0.0.1:9", apiKey: "k" }, [dep("a")], fast)),
    "unavailable"
  );
});

test("analyzeUrls returns reports by repository", async () => {
  const api = await stub(() => [
    200,
    { state: "complete", report: { repos: [cached("x").analysis] } },
  ]);
  try {
    const out = await analyzeUrls({ apiUrl: api.url, apiKey: "k" }, ["https://github.com/o/x"]);
    assert.equal(api.seen[0].path, "/v1/analyze");
    assert.equal(out.get("https://github.com/o/x")?.data.risk, "low");
  } finally {
    api.close();
  }
});

test("every manifest type the service resolves maps to its ecosystem", () => {
  assert.equal(ecosystemFor("mix"), "hex");
  assert.equal(ecosystemFor("pip"), "pypi");
  assert.equal(ecosystemFor("npm"), "npm");
  assert.equal(ecosystemFor("maven"), undefined);
  assert.equal(ecosystemFor("gradle"), undefined);
});

test("a 403 carries the service's reason", async () => {
  const api = await stub(() => [403, { error: "insufficient scope", required: "analyze" }]);
  try {
    await assert.rejects(
      analyzeBatch({ apiUrl: api.url, apiKey: "k" }, [dep("a")], fast),
      /insufficient scope/
    );
  } finally {
    api.close();
  }
});
