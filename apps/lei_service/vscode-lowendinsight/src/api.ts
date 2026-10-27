// The LowEndInsight API, without VS Code: everything here is testable with
// `node --test` against a stub server (src/test/api.test.ts).
import { ManifestType, RepoReport } from "./types";

export interface ApiConfig {
  apiUrl: string;
  apiKey: string;
}

/** A dependency as POST /v1/analyze/batch names it. */
export interface Coordinate {
  ecosystem: string;
  package: string;
  version: string;
}

export type BatchStatus = "cached" | "pending" | "uncached" | "failed";

export interface BatchResult extends Coordinate {
  status: BatchStatus;
  risk?: string;
  analysis?: RepoReport;
  error?: string;
}

export type ApiErrorKind =
  | "no-key"
  | "invalid-key"
  | "forbidden"
  | "payment-required"
  | "rate-limited"
  | "rejected"
  | "unavailable";

export class LeiApiError extends Error {
  constructor(readonly kind: ApiErrorKind, message: string) {
    super(message);
    this.name = "LeiApiError";
  }
}

export const SIGNUP_URL = "https://lowendinsight.dev/signup";

// The service resolves these registries (Lei.PackageRepository.ecosystems/0).
// Maven and Gradle are not among them: those dependencies are reported as not
// supported rather than shown with no risk, which reads as no risk found.
const ECOSYSTEMS: Partial<Record<ManifestType, string>> = {
  npm: "npm",
  mix: "hex",
  cargo: "cargo",
  go: "go",
  pip: "pypi",
  gem: "gem",
};

export function ecosystemFor(type: ManifestType): string | undefined {
  return ECOSYSTEMS[type];
}

export function coordinateKey(c: Coordinate): string {
  return `${c.ecosystem}/${c.package}@${c.version}`;
}

// The service refuses a request naming more than this (Lei.RequestScope).
const MAX_PER_REQUEST = 500;

export interface PollOptions {
  /** Between re-asks for what is still pending. */
  intervalMs?: number;
  /** Give up and report what is still pending as pending. */
  maxWaitMs?: number;
  /** Each HTTP request. */
  requestTimeoutMs?: number;
}

/**
 * Analyse dependencies by package name; the service finds each repository.
 *
 * A first request returns what is cached and queues the rest. Only the entries
 * still pending are asked about again: the service prices a request when it
 * admits it, so re-sending the whole list each poll would pay for the cached
 * entries again.
 */
export async function analyzeBatch(
  cfg: ApiConfig,
  deps: Coordinate[],
  opts: PollOptions = {}
): Promise<Map<string, BatchResult>> {
  const intervalMs = opts.intervalMs ?? 5000;
  const maxWaitMs = opts.maxWaitMs ?? 120_000;
  const results = new Map<string, BatchResult>();
  if (deps.length === 0) return results;
  requireKey(cfg);

  const unique = [...new Map(deps.map((d) => [coordinateKey(d), d])).values()];
  const deadline = Date.now() + maxWaitMs;
  let ask = unique;

  for (;;) {
    for (let i = 0; i < ask.length; i += MAX_PER_REQUEST) {
      const chunk = ask.slice(i, i + MAX_PER_REQUEST);
      const body = await post(cfg, "/v1/analyze/batch", { dependencies: chunk }, opts);
      for (const r of (body.results ?? []) as BatchResult[]) {
        results.set(coordinateKey(r), r);
      }
    }

    ask = unique.filter((d) => results.get(coordinateKey(d))?.status === "pending");
    if (ask.length === 0 || Date.now() + intervalMs > deadline) return results;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}

/** Analyse repositories by URL, for dependencies that name one directly. */
export async function analyzeUrls(
  cfg: ApiConfig,
  urls: string[],
  opts: PollOptions = {}
): Promise<Map<string, RepoReport>> {
  const reports = new Map<string, RepoReport>();
  if (urls.length === 0) return reports;
  requireKey(cfg);

  for (let i = 0; i < urls.length; i += MAX_PER_REQUEST) {
    const body = await post(
      cfg,
      "/v1/analyze",
      { urls: urls.slice(i, i + MAX_PER_REQUEST), cache_mode: "blocking" },
      opts
    );
    for (const repo of (body.report?.repos ?? []) as RepoReport[]) {
      if (repo?.data?.repo) reports.set(repo.data.repo, repo);
    }
  }
  return reports;
}

function requireKey(cfg: ApiConfig): void {
  if (!cfg.apiKey) {
    throw new LeiApiError(
      "no-key",
      `No LowEndInsight API key is set. Get one free during the beta at ${SIGNUP_URL}.`
    );
  }
}

async function post(
  cfg: ApiConfig,
  path: string,
  payload: unknown,
  opts: PollOptions
): Promise<any> {
  let res: Response;
  try {
    res = await fetch(cfg.apiUrl.replace(/\/+$/, "") + path, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        Authorization: `Bearer ${cfg.apiKey}`,
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(opts.requestTimeoutMs ?? 90_000),
    });
  } catch (err) {
    const why = err instanceof Error ? err.message : String(err);
    throw new LeiApiError("unavailable", `Could not reach ${cfg.apiUrl}: ${why}`);
  }

  const text = await res.text();
  switch (res.status) {
    case 200:
    case 202:
      try {
        return JSON.parse(text);
      } catch {
        throw new LeiApiError("unavailable", `${cfg.apiUrl} returned a response that is not JSON`);
      }
    case 401:
      throw new LeiApiError(
        "invalid-key",
        `The API key was refused (${errorOf(text) ?? "401"}). Check it, or get a new one at ${SIGNUP_URL}.`
      );
    // A real key the service will not let do this: an inactive organisation,
    // or a key without the analyze scope.
    case 403:
      throw new LeiApiError(
        "forbidden",
        `The API key is not allowed to analyse (${errorOf(text) ?? "403"}). Check the key, or get a new one at ${SIGNUP_URL}.`
      );
    // What the service answers a request with no key: a payment challenge,
    // which an agent can pay. A person in an editor wants a key instead.
    case 402:
      throw new LeiApiError(
        "payment-required",
        `LowEndInsight asked for payment, which means no valid API key reached it. Get one free during the beta at ${SIGNUP_URL}.`
      );
    case 429:
      throw new LeiApiError(
        "rate-limited",
        "LowEndInsight's rate limit was reached. Try again in a minute."
      );
    case 400:
    case 422:
      throw new LeiApiError("rejected", `LowEndInsight rejected the request: ${errorOf(text) ?? text}`);
    default:
      throw new LeiApiError("unavailable", `LowEndInsight answered HTTP ${res.status}`);
  }
}

function errorOf(text: string): string | undefined {
  try {
    const parsed = JSON.parse(text);
    return typeof parsed?.error === "string" ? parsed.error : undefined;
  } catch {
    return undefined;
  }
}
