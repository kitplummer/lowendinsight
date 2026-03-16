import * as https from "https";
import * as http from "http";
import * as vscode from "vscode";
import { AnalysisReport } from "./types";

function getConfig() {
  const cfg = vscode.workspace.getConfiguration("lowendinsight");
  return {
    apiUrl: cfg.get<string>("apiUrl", "http://localhost:4000"),
    apiToken: cfg.get<string>("apiToken", ""),
    cacheMode: cfg.get<string>("cacheMode", "blocking"),
    cacheTimeout: cfg.get<number>("cacheTimeout", 60000),
  };
}

function request(
  url: string,
  method: string,
  body?: string
): Promise<{ status: number; data: string }> {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const transport = parsed.protocol === "https:" ? https : http;
    const cfg = getConfig();

    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      Accept: "application/json",
    };
    if (cfg.apiToken) {
      headers["Authorization"] = `Bearer ${cfg.apiToken}`;
    }

    const req = transport.request(
      {
        hostname: parsed.hostname,
        port: parsed.port,
        path: parsed.pathname + parsed.search,
        method,
        headers,
        timeout: cfg.cacheTimeout + 10000,
      },
      (res) => {
        let data = "";
        res.on("data", (chunk: Buffer) => (data += chunk.toString()));
        res.on("end", () =>
          resolve({ status: res.statusCode ?? 0, data })
        );
      }
    );
    req.on("error", reject);
    req.on("timeout", () => {
      req.destroy();
      reject(new Error("Request timed out"));
    });
    if (body) {
      req.write(body);
    }
    req.end();
  });
}

export async function analyzeUrls(
  urls: string[]
): Promise<AnalysisReport> {
  const cfg = getConfig();
  const payload = JSON.stringify({
    urls,
    cache_mode: cfg.cacheMode,
    cache_timeout: cfg.cacheTimeout,
  });

  const res = await request(
    `${cfg.apiUrl}/v1/analyze`,
    "POST",
    payload
  );

  if (res.status === 401) {
    throw new Error("LEI API authentication failed. Check your API token.");
  }
  if (res.status === 422) {
    throw new Error(`LEI API rejected request: ${res.data}`);
  }

  const report: AnalysisReport = JSON.parse(res.data);

  // If async, poll until complete
  if (report.state === "incomplete" && report.uuid) {
    return pollForResult(report.uuid);
  }

  return report;
}

export async function getAnalysis(
  uuid: string
): Promise<AnalysisReport> {
  const cfg = getConfig();
  const res = await request(
    `${cfg.apiUrl}/v1/analyze/${uuid}`,
    "GET"
  );

  if (res.status === 404) {
    throw new Error(`No analysis found for UUID: ${uuid}`);
  }

  return JSON.parse(res.data);
}

async function pollForResult(
  uuid: string,
  maxAttempts = 30,
  intervalMs = 2000
): Promise<AnalysisReport> {
  for (let i = 0; i < maxAttempts; i++) {
    await new Promise((r) => setTimeout(r, intervalMs));
    const report = await getAnalysis(uuid);
    if (report.state === "complete") {
      return report;
    }
  }
  throw new Error(
    `Analysis ${uuid} did not complete after ${maxAttempts} polling attempts`
  );
}
