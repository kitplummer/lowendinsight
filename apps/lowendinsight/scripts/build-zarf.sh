#!/bin/bash
# Build script for LEI Zarf package
# Creates an air-gapped deployable package

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION="${VERSION:-0.8.1}"
REGISTRY="${REGISTRY:-ghcr.io/kitplummer}"

cd "$PROJECT_DIR"

echo "=== Building LEI for Zarf Packaging ==="
echo "Version: $VERSION"
echo "Registry: $REGISTRY"
echo ""

# Step 1: Build the production Docker image
echo "Step 1: Building production Docker image..."
docker build \
    -f Dockerfile.prod \
    -t "${REGISTRY}/lowendinsight:${VERSION}" \
    -t "${REGISTRY}/lowendinsight:latest" \
    --build-arg MIX_ENV=prod \
    .

echo "Docker image built: ${REGISTRY}/lowendinsight:${VERSION}"
echo ""

# Step 2: Extract SBOM from the built image
echo "Step 2: Extracting SBOM from container..."
mkdir -p sbom-output
docker run --rm "${REGISTRY}/lowendinsight:${VERSION}" sbom cyclonedx > sbom-output/lei-container.cdx.json
docker run --rm "${REGISTRY}/lowendinsight:${VERSION}" sbom spdx > sbom-output/lei-container.spdx.json
echo "SBOM extracted to sbom-output/"
echo ""

# Step 3: Create Zarf package
echo "Step 3: Creating Zarf package..."
if command -v zarf &> /dev/null; then
    zarf package create . --confirm
    echo ""
    echo "Zarf package created successfully!"
    ls -la zarf-package-lei-*.tar.zst 2>/dev/null || echo "Package file location may vary"
else
    echo "WARNING: 'zarf' command not found. Skipping Zarf package creation."
    echo "Install Zarf to create the air-gapped package:"
    echo "  brew install defenseunicorns/tap/zarf"
    echo "  OR"
    echo "  curl -sL https://github.com/defenseunicorns/zarf/releases/latest/download/zarf_linux_amd64 -o /usr/local/bin/zarf && chmod +x /usr/local/bin/zarf"
fi

echo ""
echo "=== Build Complete ==="
echo ""
echo "To test the container locally:"
echo "  docker run --rm -v \$PWD:/workspace ${REGISTRY}/lowendinsight:${VERSION} scan"
echo ""
echo "To deploy with Zarf:"
echo "  zarf package deploy zarf-package-lei-*.tar.zst"
