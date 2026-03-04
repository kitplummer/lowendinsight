export type RiskLevel = "critical" | "high" | "medium" | "low";

export interface RepoResults {
  commit_currency_risk: RiskLevel;
  commit_currency_weeks: number;
  contributor_count: number;
  contributor_risk: RiskLevel;
  functional_contributor_names?: string[];
  functional_contributors: number;
  functional_contributors_risk: RiskLevel;
  large_recent_commit_risk: RiskLevel;
  recent_commit_size_in_percent_of_codebase: number;
}

export interface RiskConfig {
  critical_contributor_level?: number;
  high_contributor_level?: number;
  medium_contributor_level?: number;
  critical_currency_level?: number;
  high_currency_level?: number;
  medium_currency_level?: number;
  critical_large_commit_level?: number;
  high_large_commit_level?: number;
  medium_large_commit_level?: number;
  critical_functional_contributors_level?: number;
  high_functional_contributors_level?: number;
  medium_functional_contributors_level?: number;
}

export interface RepoData {
  repo: string;
  risk: RiskLevel;
  results: RepoResults;
  config?: RiskConfig;
  project_types?: Record<string, string[]>;
}

export interface RepoHeader {
  uuid: string;
  start_time: string;
  end_time: string;
  duration: number;
  library_version: string;
  source_client: string;
}

export interface RepoReport {
  data: RepoData;
  header: RepoHeader;
}

export interface ReportMetadata {
  repo_count: number;
  times: {
    start_time: string;
    end_time: string;
    duration: number;
  };
  risk_counts: Partial<Record<RiskLevel, number>>;
  cache_status?: {
    hits: number;
    misses: number;
    per_repo: ("hit" | "miss" | "stale")[];
  };
}

export interface AnalysisReport {
  state: "complete" | "incomplete";
  uuid: string;
  report?: {
    uuid: string;
    repos: RepoReport[];
  };
  metadata?: ReportMetadata;
  error?: string;
}

/** A dependency extracted from a manifest file with its position in the document. */
export interface ManifestDependency {
  name: string;
  version?: string;
  gitUrl?: string;
  line: number;
  startChar: number;
  endChar: number;
}

/** Parsed manifest with its dependencies and file info. */
export interface ParsedManifest {
  filePath: string;
  type: ManifestType;
  dependencies: ManifestDependency[];
}

export type ManifestType =
  | "npm"
  | "mix"
  | "cargo"
  | "go"
  | "pip"
  | "gem"
  | "maven"
  | "gradle";

/** Resolved dependency with LEI analysis results attached. */
export interface AnalyzedDependency {
  dep: ManifestDependency;
  manifestPath: string;
  repoUrl?: string;
  report?: RepoReport;
  risk?: RiskLevel;
}
