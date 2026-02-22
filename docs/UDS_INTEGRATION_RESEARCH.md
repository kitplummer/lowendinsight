# LEI Integration into Defense Unicorns UDS Product Portfolio

## Executive Summary

This document analyzes integration opportunities between LowEndInsight (LEI) and Defense Unicorns' Unicorn Delivery Service (UDS) product portfolio. LEI's "bus-factor" risk analysis capabilities complement UDS's existing supply chain security features, addressing a critical gap in assessing upstream dependency maintainability and sustainability risks.

**Key Finding:** UDS generates SBOMs and performs CVE scanning but lacks visibility into project health metrics that predict future vulnerability response capability. LEI fills this gap by assessing contributor diversity, commit currency, and maintenance sustainability.

## Technology Overview

### LEI (LowEndInsight)

LEI is an Elixir-based supply chain risk analysis library that evaluates Git repositories for maintainability risks:

| Metric | Description | Risk Indicators |
|--------|-------------|-----------------|
| Functional Contributors | Contributors with meaningful commit share | <2 = critical, <3 = high, <5 = medium |
| Commit Currency | Weeks since last commit | >104 weeks = critical, >52 = high |
| Large Recent Commits | Code volatility percentage | >40% = critical, >30% = high |
| SBOM Presence | Bill of materials artifact detection | Missing = configurable risk |
| Contributor Count | Total unique contributors | Lower = higher risk |

**Supported Ecosystems:** Elixir/Mix, Node.js/npm, Python/pip, Go, Rust/Cargo, Ruby/Gem, Maven, Gradle

### Defense Unicorns UDS

UDS is a secure, airgap-native platform for deploying software to military systems, built on three core components:

- **Zarf**: Declarative packaging and deployment engine for Kubernetes
- **Pepr**: Policy automation and runtime configuration
- **Lula**: Compliance-as-code framework for security controls

**Current Supply Chain Security Features:**
- SBOM generation via Syft (embedded in Zarf)
- CVE scanning per release
- Cryptographic package signing
- NIST SP 800-53 compliance artifacts

## Integration Gap Analysis

| Capability | UDS Current State | LEI Addresses |
|------------|-------------------|---------------|
| Known vulnerability detection | CVE scanning | N/A (complementary) |
| Software composition analysis | Syft SBOM generation | N/A (complementary) |
| **Maintainability risk assessment** | Not addressed | Functional contributor analysis |
| **Project abandonment detection** | Not addressed | Commit currency tracking |
| **Bus-factor risk quantification** | Not addressed | Contributor diversity metrics |
| **Upstream response capability** | Not addressed | Combined health scoring |

## Concrete Integration Recommendations

### 1. Pre-Package Gate Integration (Priority: High)

**Objective:** Prevent high-risk dependencies from entering Zarf packages before creation.

**Implementation:**
```
┌─────────────────┐     ┌─────────────┐     ┌──────────────┐
│ zarf.yaml       │────▶│ LEI Scan    │────▶│ Package      │
│ dependencies    │     │ (threshold  │     │ Creation     │
│                 │     │  check)     │     │ (if pass)    │
└─────────────────┘     └─────────────┘     └──────────────┘
```

**Technical Approach:**
- Create a Zarf action hook that invokes LEI analysis before `zarf package create`
- Parse dependency manifests from component directories
- Block package creation if any dependency exceeds configured risk thresholds
- Generate compliance report for audit trail

**Zarf Action Example:**
```yaml
components:
  - name: mission-app
    actions:
      onCreate:
        before:
          - cmd: lei-scan --path . --threshold high --format json
            description: "LEI supply chain risk assessment"
```

**Deliverables:**
- `lei-zarf-gate` CLI wrapper for Zarf integration
- Configurable risk threshold mappings
- JSON/SARIF output for CI/CD consumption

### 2. UDS Registry Metadata Enrichment (Priority: High)

**Objective:** Publish LEI risk scores alongside packages in UDS Registry for informed deployment decisions.

**Implementation:**
```
┌──────────────┐     ┌─────────────┐     ┌──────────────────┐
│ Zarf Package │────▶│ LEI         │────▶│ UDS Registry     │
│ + SBOM       │     │ Analysis    │     │ + Risk Metadata  │
└──────────────┘     └─────────────┘     └──────────────────┘
```

**Technical Approach:**
- Extract dependency URLs from Zarf package SBOMs
- Run LEI bulk analysis on extracted repositories
- Attach LEI report as OCI annotation or separate artifact
- Display risk scores in UDS Registry UI alongside CVE data

**OCI Annotation Schema:**
```json
{
  "dev.defenseunicorns.lei.report": {
    "overall_risk": "medium",
    "functional_contributors_risk": "low",
    "commit_currency_risk": "medium",
    "high_risk_dependencies": ["dep-a", "dep-b"],
    "scan_timestamp": "2026-02-05T10:00:00Z"
  }
}
```

**Deliverables:**
- LEI-to-OCI annotation converter
- UDS Registry UI component for risk display
- API endpoint for programmatic risk queries

### 3. Pepr Policy Integration (Priority: Medium)

**Objective:** Enforce maintainability requirements at deployment time via UDS policy engine.

**Implementation:**
```
┌─────────────────┐     ┌─────────────────┐     ┌──────────────┐
│ UDS Bundle      │────▶│ Pepr Policy     │────▶│ Deployment   │
│ Deployment      │     │ (LEI threshold  │     │ (if pass)    │
│                 │     │  validation)    │     │              │
└─────────────────┘     └─────────────────┘     └──────────────┘
```

**Technical Approach:**
- Create Pepr capability that reads LEI annotations from packages
- Define admission policies based on risk thresholds
- Support exemption mechanism for approved exceptions
- Log policy decisions for compliance audit

**Pepr Policy Example:**
```typescript
When(a.Package)
  .IsCreatedOrUpdated()
  .Validate((pkg) => {
    const leiRisk = pkg.metadata?.annotations?.["dev.defenseunicorns.lei.report"];
    if (leiRisk?.overall_risk === "critical") {
      return pkg.Deny("Package contains critical supply chain risk");
    }
    return pkg.Approve();
  });
```

**Deliverables:**
- `uds-pepr-lei` capability module
- Configurable policy templates
- Exemption CRD for approved exceptions

### 4. Lula Compliance Control Mapping (Priority: Medium)

**Objective:** Map LEI metrics to NIST SP 800-53 supply chain controls for ATO support.

**Relevant NIST Controls:**
| Control | Description | LEI Mapping |
|---------|-------------|-------------|
| SR-3 | Supply Chain Controls | Overall risk score |
| SR-4 | Provenance | Contributor analysis + SBOM detection |
| SR-5 | Acquisition Strategies | Commit currency (maintenance likelihood) |
| SR-6 | Supplier Assessments | Functional contributor risk |
| SA-12 | Supply Chain Risk Management | Combined LEI report |

**Technical Approach:**
- Create Lula component definitions mapping LEI outputs to controls
- Generate compliance evidence artifacts from LEI reports
- Integrate into UDS Core compliance documentation pipeline

**Deliverables:**
- Lula component YAML for LEI controls
- OSCAL-formatted evidence generation
- SCTM (Security Control Traceability Matrix) entries

### 5. CI/CD Pipeline Integration (Priority: High)

**Objective:** Integrate LEI into standard UDS development workflows.

**GitHub Actions Integration:**
```yaml
name: UDS Package Build
on: [push, pull_request]

jobs:
  lei-analysis:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: kitplummer/lowendinsight-action@v1
        with:
          threshold: high
          fail-on-risk: true
          output-format: sarif
      - uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: lei-results.sarif

  package-build:
    needs: lei-analysis
    runs-on: ubuntu-latest
    steps:
      - uses: defenseunicorns/setup-zarf@v1
      - run: zarf package create --confirm
```

**Deliverables:**
- Updated `lowendinsight-action` with UDS-specific outputs
- SARIF output format for GitHub Security tab integration
- Reusable workflow templates for UDS projects

## Implementation Roadmap

### Phase 1: Foundation (Weeks 1-4)
- [ ] Create `lei-zarf-gate` CLI tool
- [ ] Implement JSON/SARIF output formats
- [ ] Document integration patterns
- [ ] Publish updated GitHub Action

### Phase 2: Registry Integration (Weeks 5-8)
- [ ] Define OCI annotation schema for LEI data
- [ ] Build LEI-to-annotation converter
- [ ] Create UDS Registry UI component
- [ ] API endpoint implementation

### Phase 3: Policy & Compliance (Weeks 9-12)
- [ ] Develop Pepr capability module
- [ ] Create Lula component definitions
- [ ] Map to NIST SP 800-53 controls
- [ ] Generate compliance documentation

### Phase 4: Production Hardening (Weeks 13-16)
- [ ] Performance optimization for bulk analysis
- [ ] Caching layer for repeated scans
- [ ] Enterprise support documentation
- [ ] Security review and hardening

## Technical Considerations

### Performance

LEI analysis requires Git repository cloning, which can be slow for large repositories. Recommendations:

1. **Caching:** Implement result caching keyed by repository URL + commit hash
2. **Shallow Clones:** Use `--depth` option where full history isn't needed
3. **Parallel Processing:** LEI already supports configurable `jobs_per_core_max`
4. **Incremental Analysis:** Only re-analyze changed dependencies between builds

### Airgap Compatibility

LEI currently requires network access to clone repositories. For airgap environments:

1. **Pre-analysis:** Run LEI analysis before crossing airgap boundary
2. **Report Bundling:** Include LEI reports in Zarf packages as artifacts
3. **Offline Validation:** Validate against pre-computed risk baselines
4. **Mirror Support:** Point LEI at internal Git mirrors when available

### Data Sensitivity

LEI does not collect or transmit data externally. All analysis is local. However:

1. Repository URLs may reveal sensitive project names
2. Contributor information (names, emails) appears in reports
3. Consider redaction options for classified environments

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Integration adoption | 50% of new UDS packages | Registry annotation presence |
| Risk detection rate | Identify 80% of unmaintained deps | Compare to known abandonware |
| False positive rate | <10% | Manual review sampling |
| Build time impact | <5 minutes added | CI/CD timing metrics |
| Compliance coverage | 5 NIST controls mapped | Lula component count |

## Conclusion

LEI integration into UDS addresses a significant blind spot in current supply chain security: the assessment of upstream project health and maintainability. While UDS excels at vulnerability detection and secure packaging, it cannot predict whether dependencies will receive timely security patches based on contributor engagement and project activity.

The recommended phased approach prioritizes high-impact, low-friction integrations (pre-package gates and CI/CD pipelines) before deeper platform integration (Registry metadata and Pepr policies). This allows immediate value delivery while building toward comprehensive supply chain risk management.

## References

- [UDS Documentation](https://uds.defenseunicorns.com/)
- [Zarf SBOM Documentation](https://docs.zarf.dev/ref/sboms/)
- [UDS Core GitHub](https://github.com/defenseunicorns/uds-core)
- [Defense Unicorns UDS Registry Announcement](https://www.prnewswire.com/news-releases/defense-unicorns-launches-uds-registry-ensuring-software-is-ready-for-any-mission-anytime-anywhere-302493897.html)
- [NIST SP 800-53 Rev 5 - Supply Chain Risk Management](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final)
