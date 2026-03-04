# LEI OCI Annotation Schema

OCI annotations for publishing LowEndInsight risk scores as container image metadata
in OCI-compliant registries (including UDS Registry).

## Namespace

All LEI annotations use the `dev.lowendinsight` reverse-DNS prefix, following the
[OCI Image Spec annotation conventions](https://github.com/opencontainers/image-spec/blob/main/annotations.md).

## Annotation Keys

### Summary

| Key | Type | Values | Description |
|-----|------|--------|-------------|
| `dev.lowendinsight.risk` | enum | `critical`, `high`, `medium`, `low` | Rolled-up risk for the analyzed source |
| `dev.lowendinsight.contributor-risk` | enum | `critical`, `high`, `medium`, `low` | Risk based on unique contributor count |
| `dev.lowendinsight.contributor-count` | integer | `>= 0` | Number of unique contributors |
| `dev.lowendinsight.commit-currency-risk` | enum | `critical`, `high`, `medium`, `low` | Risk based on time since last commit |
| `dev.lowendinsight.commit-currency-weeks` | integer | `>= 0` | Weeks since most recent commit |
| `dev.lowendinsight.functional-contributors-risk` | enum | `critical`, `high`, `medium`, `low` | Risk based on core/functional contributors |
| `dev.lowendinsight.functional-contributors` | integer | `>= 0` | Number of functional (core) contributors |
| `dev.lowendinsight.large-recent-commit-risk` | enum | `critical`, `high`, `medium`, `low` | Risk based on recent commit size volatility |
| `dev.lowendinsight.sbom-risk` | enum | `critical`, `high`, `medium`, `low` | Risk based on SBOM presence |
| `dev.lowendinsight.analyzed-at` | RFC 3339 | timestamp | When the LEI analysis was performed |
| `dev.lowendinsight.version` | semver | e.g. `0.9.0` | LEI version that produced the analysis |
| `dev.lowendinsight.source-repo` | URL | git URL | Source repository that was analyzed |

### Risk Levels

Risk values follow the LEI four-tier model:

| Level | Meaning |
|-------|---------|
| `critical` | Immediate attention required; single-maintainer or abandoned project |
| `high` | Significant concern; limited contributors or stale commits |
| `medium` | Moderate concern; acceptable for non-critical paths |
| `low` | Healthy project; active maintenance and diverse contributors |

### Threshold Defaults

Risk thresholds are configurable via environment variables. Defaults:

| Metric | Critical | High | Medium | Low |
|--------|----------|------|--------|-----|
| Contributors | < 2 | 2-3 | 3-5 | >= 5 |
| Commit currency (weeks) | >= 104 | 52-104 | 26-52 | < 26 |
| Functional contributors | < 2 | 2-3 | 3-5 | >= 5 |
| Large commit size (%) | >= 50% | 30-50% | 20-30% | < 20% |

## Usage

### Applying Annotations at Build Time

Annotations can be applied during image build using standard OCI tooling:

```bash
# With Docker buildx
docker buildx build \
  --annotation "dev.lowendinsight.risk=critical" \
  --annotation "dev.lowendinsight.contributor-risk=critical" \
  --annotation "dev.lowendinsight.contributor-count=1" \
  -t myimage:latest .

# With ORAS
oras push registry.example.com/myimage:latest \
  --annotation "dev.lowendinsight.risk=critical" \
  ./artifact.tar
```

### Applying Annotations Post-Build

For existing images in a registry, annotations can be attached via OCI referrers:

```bash
# Generate annotations JSON from LEI analysis
mix lei.analyze https://github.com/org/repo --format oci-annotations > annotations.json

# Attach as OCI referrer
oras attach registry.example.com/myimage:latest \
  --artifact-type "application/vnd.lowendinsight.risk.v1+json" \
  annotations.json
```

### Querying Annotations

```bash
# With crane
crane manifest registry.example.com/myimage:latest | jq '.annotations'

# With ORAS
oras manifest fetch registry.example.com/myimage:latest --descriptor | jq '.annotations'
```

## Integration with UDS Registry

In a UDS (Unicorn Delivery Service) deployment, LEI annotations enable policy
enforcement at the registry level:

1. **Zarf packages** bundle container images with SBOMs
2. **LEI analyzes** source repos referenced in SBOMs
3. **Annotations are injected** into image manifests in the UDS registry
4. **Admission controllers** (Pepr/Gatekeeper) can gate deployments on risk levels

## JSON Representation

When serialized as a JSON object (e.g., for `--annotation-file` flags):

```json
{
  "dev.lowendinsight.risk": "critical",
  "dev.lowendinsight.contributor-risk": "critical",
  "dev.lowendinsight.contributor-count": "1",
  "dev.lowendinsight.commit-currency-risk": "critical",
  "dev.lowendinsight.commit-currency-weeks": "563",
  "dev.lowendinsight.functional-contributors-risk": "critical",
  "dev.lowendinsight.functional-contributors": "1",
  "dev.lowendinsight.large-recent-commit-risk": "low",
  "dev.lowendinsight.sbom-risk": "medium",
  "dev.lowendinsight.analyzed-at": "2024-01-01T00:00:00Z",
  "dev.lowendinsight.version": "0.9.0",
  "dev.lowendinsight.source-repo": "https://github.com/org/repo"
}
```

All annotation values are strings per the OCI spec. Numeric values are
string-encoded integers.
