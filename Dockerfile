# Multi-stage build for Istio Azure VM Management Service
FROM golang:1.21-alpine AS builder

# Set working directory
WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git ca-certificates

# Copy go mod files
COPY go.mod go.sum ./

# Download dependencies
RUN go mod download

# Copy source code
COPY . .

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build -o vm-manager ./cmd/vm-manager

# Final stage - create runtime image with all required tools
FROM alpine:3.18

# Set environment variables
ENV AZURE_CLI_VERSION=2.53.0
ENV KUBECTL_VERSION=v1.28.3
ENV ISTIOCTL_VERSION=1.19.3
ENV TERRAFORM_VERSION=1.6.2

# Install base packages
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    yq \
    ca-certificates \
    openssh-client \
    git \
    python3 \
    py3-pip \
    gcc \
    musl-dev \
    python3-dev \
    libffi-dev \
    openssl-dev \
    cargo \
    make

# Install Azure CLI
RUN pip3 install azure-cli==${AZURE_CLI_VERSION}

# Install kubectl
RUN curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/

# Install istioctl
RUN curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIOCTL_VERSION} TARGET_ARCH=x86_64 sh - && \
    mv istio-${ISTIOCTL_VERSION}/bin/istioctl /usr/local/bin/ && \
    rm -rf istio-${ISTIOCTL_VERSION}

# Install Terraform (optional, for infrastructure management)
RUN curl -fsSL https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip -o terraform.zip && \
    unzip terraform.zip && \
    mv terraform /usr/local/bin/ && \
    rm terraform.zip

# Create non-root user
RUN addgroup -g 1001 vmmanager && \
    adduser -D -u 1001 -G vmmanager vmmanager

# Create necessary directories
RUN mkdir -p /app/configs /app/certs /app/logs /app/templates && \
    chown -R vmmanager:vmmanager /app

# Copy built application
COPY --from=builder /app/vm-manager /app/vm-manager

# Copy configuration templates and scripts
COPY configs/ /app/configs/
COPY templates/ /app/templates/
COPY vm-image/cloud-init-istio-vm.yaml /app/templates/

# Set working directory
WORKDIR /app

# Switch to non-root user
USER vmmanager

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Expose port
EXPOSE 8080

# Run the application
ENTRYPOINT ["./vm-manager"]
CMD ["--config", "/app/configs/config.yaml"]