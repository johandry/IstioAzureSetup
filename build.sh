#!/bin/bash
set -e

# Build script for Istio VM Manager
echo "Building Istio VM Manager..."

# Set build variables
IMAGE_NAME="istio-vm-manager"
VERSION="${1:-latest}"
DOCKERFILE_PATH="${2:-Dockerfile}"

# Build Docker image
echo "Building Docker image: ${IMAGE_NAME}:${VERSION}"
docker build -t "${IMAGE_NAME}:${VERSION}" -f "${DOCKERFILE_PATH}" .

# Tag as latest if version is not latest
if [ "$VERSION" != "latest" ]; then
    docker tag "${IMAGE_NAME}:${VERSION}" "${IMAGE_NAME}:latest"
fi

echo "Build completed successfully!"
echo "Image: ${IMAGE_NAME}:${VERSION}"

# Optional: Run tests
if [ "${RUN_TESTS:-false}" = "true" ]; then
    echo "Running tests..."
    # Add test commands here
    echo "Tests completed!"
fi

echo "Available commands:"
echo "  docker run -d -p 8080:8080 ${IMAGE_NAME}:${VERSION}"
echo "  docker-compose up -d"