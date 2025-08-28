#!/bin/bash

# VM Mesh Integration Script
# This script configures the VM to be part of the Istio mesh
# Uses local workspace and accepts VM_IP as parameter to avoid double execution

set -e

# Shared configuration variables
RESOURCE_GROUP="istio-playground-rg"
VM_NAME="istio-vm"

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use local workspace (can be overridden by environment variable)
WORK_DIR="$SCRIPT_DIR/../workspace/vm-mesh-setup"
SERVICE_ACCOUNT="vm-workload"
VM_NAMESPACE="vm-workloads"
VM_APP="vm-web-service"
VM_VERSION="v1.0"
VM_NETWORK="vm-network" # Multi-Network

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get VM IP using Azure CLI
get_vm_ip() {
    print_status "Getting VM IP address..."
    
    VM_IP=$(az vm show -d -g $RESOURCE_GROUP -n $VM_NAME --query publicIps -o tsv 2>/dev/null)
    
    if [ -z "$VM_IP" ] || [ "$VM_IP" = "null" ]; then
        print_error "Could not get VM IP address for VM: $VM_NAME in resource group: $RESOURCE_GROUP"
        exit 1
    fi
    
    print_status "✓ VM IP found: $VM_IP"
}

# Create namespace and service account in the cluster with Azure best practices
setup_cluster_resources() {
    print_status "Setting up cluster resources for VM integration with Azure optimizations..."
    
    # Create namespace with proper labels for Azure monitoring
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $VM_NAMESPACE
  labels:
    istio-injection: enabled
    azure.workload.identity/use: "true"
    name: $VM_NAMESPACE
spec: {}
EOF
    
    # Create service account with Azure workload identity support
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT
  namespace: $VM_NAMESPACE
  labels:
    azure.workload.identity/use: "true"
  annotations:
    azure.workload.identity/client-id: ""
automountServiceAccountToken: true
EOF
    
    # Create workload group with Azure network considerations
    cat > "$WORK_DIR/vm-files/workloadgroup.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: WorkloadGroup
metadata:
  name: $VM_APP
  namespace: $VM_NAMESPACE
  labels:
    app: $VM_APP
    azure.resource: vm-workload
spec:
  metadata:
    labels:
      app: $VM_APP
      version: $VM_VERSION
      azure.zone: westus
  template:
    serviceAccount: $SERVICE_ACCOUNT
    network: $VM_NETWORK
    ports:
      http: 8080
      metrics: 15020
      health: 15021
  probe:
    httpGet:
      port: 8080
EOF

    kubectl apply -f "$WORK_DIR/vm-files/workloadgroup.yaml"

    print_status "✓ Cluster resources configured with Azure optimizations"
}

# Apply VM configuration files with immediate VM IP
apply_vm_config() {
    print_status "Applying VM configuration..."

    # Service configuration with Azure load balancer annotations
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $VM_APP
  namespace: $VM_NAMESPACE
  labels:
    app: $VM_APP
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: "/health"
    service.beta.kubernetes.io/azure-load-balancer-health-probe-interval: "5"
spec:
  selector:
    app: $VM_APP
  ports:
  - port: 8080
    targetPort: 8080
    name: http
    protocol: TCP
  - port: 15020
    targetPort: 15020
    name: metrics
    protocol: TCP
  type: ClusterIP
EOF

    # VirtualService configuration with timeout settings for Azure
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: $VM_APP
  namespace: $VM_NAMESPACE
spec:
  hosts:
  - $VM_APP.$VM_NAMESPACE.svc.cluster.local
  http:
  - match:
    - uri:
        prefix: /
    route:
    - destination:
        host: $VM_APP.$VM_NAMESPACE.svc.cluster.local
        port:
          number: 8080
    timeout: 30s
    retries:
      attempts: 3
      perTryTimeout: 10s
EOF

    # DestinationRule configuration with Azure-optimized settings
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: $VM_APP
  namespace: $VM_NAMESPACE
spec:
  host: $VM_APP.$VM_NAMESPACE.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
    connectionPool:
      tcp:
        maxConnections: 100
        connectTimeout: 10s
      http:
        http1MaxPendingRequests: 64
        maxRequestsPerConnection: 2
    outlierDetection:
      consecutiveErrors: 3
      interval: 30s
      baseEjectionTime: 30s
EOF
    
    # WorkloadEntry configuration with Azure health checks
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  annotations:
    istio.io/autoRegistrationGroup: $VM_APP
  name: $VM_APP-vm
  namespace: $VM_NAMESPACE
  labels:
    app: $VM_APP
    azure.resource: vm-instance
spec:
  address: "$VM_IP"
  labels:
    app: $VM_APP
    version: $VM_VERSION
    azure.zone: westus
  serviceAccount: $SERVICE_ACCOUNT
  network: "vm-network"
  ports:
    http: 8080
    metrics: 15020
    health: 15021
EOF

    # ServiceEntry configuration with proper Azure networking
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: $VM_APP-vm
  namespace: $VM_NAMESPACE
  labels:
    azure.resource: vm-service-entry
spec:
  hosts:
  - $VM_APP.$VM_NAMESPACE.svc.cluster.local
  location: MESH_EXTERNAL
  ports:
  - number: 8080
    name: http
    protocol: HTTP
  - number: 15020
    name: metrics
    protocol: HTTP
  resolution: DNS
  addresses:
  - "$VM_IP"
  workloadSelector:
    labels:
      app: $VM_APP
EOF

    print_status "✓ VM configuration files applied"
}

# Generate Istio service account token with enhanced security
# generate_istio_token() {
#     print_status "Generating Istio service account token with enhanced security..."
    
#     # Create token request with expiration
#     cat > "$WORK_DIR/cluster-configs/tokenrequest.yaml" <<EOF
# apiVersion: v1
# kind: Secret
# metadata:
#   name: $SERVICE_ACCOUNT-token
#   namespace: $VM_NAMESPACE
#   annotations:
#     kubernetes.io/service-account.name: $SERVICE_ACCOUNT
# type: kubernetes.io/service-account-token
# EOF

#     # Apply the token request
#     kubectl apply -f "$WORK_DIR/cluster-configs/tokenrequest.yaml"
    
#     # Wait for token with better error handling
#     print_status "Waiting for service account token generation..."
#     local token_ready=false
#     for i in {1..60}; do
#         if kubectl get secret $SERVICE_ACCOUNT-token -n $VM_NAMESPACE -o jsonpath='{.data.token}' &>/dev/null; then
#             local token_data=$(kubectl get secret $SERVICE_ACCOUNT-token -n $VM_NAMESPACE -o jsonpath='{.data.token}' 2>/dev/null)
#             if [ -n "$token_data" ]; then
#                 token_ready=true
#                 break
#             fi
#         fi
#         sleep 2
#         if [ $((i % 10)) -eq 0 ]; then
#             print_status "Still waiting for token... ($i/60)"
#         fi
#     done
    
#     if [ "$token_ready" = false ]; then
#         print_error "Timeout waiting for service account token generation"
#         exit 1
#     fi
    
#     # Extract the token to local workspace
#     kubectl get secret $SERVICE_ACCOUNT-token -n $VM_NAMESPACE -o jsonpath='{.data.token}' | base64 -d > "$WORK_DIR/vm-files/istio-token"
    
#     if [ -s "$WORK_DIR/vm-files/istio-token" ]; then
#         print_status "✓ Istio service account token generated: $WORK_DIR/vm-files/istio-token"
#     else
#         print_error "Failed to generate Istio service account token"
#         exit 1
#     fi
# }

# Generate comprehensive VM files with Azure optimizations
generate_vm_files() {
    print_status "Generating comprehensive VM files for Azure deployment..."

    # Get istiod service ingress IP
    local istiod_ip=$(kubectl get svc istiod -n istio-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -z "$istiod_ip" ]; then
        print_error "Could not get istiod service IP"
        exit 1
    fi

    istioctl x workload entry configure -f "$WORK_DIR/vm-files/workloadgroup.yaml" -o "$WORK_DIR/vm-files" --ingressIP "$istiod_ip"
    rm -f "$WORK_DIR/vm-files/workloadgroup.yaml"

#     # Get cluster root certificate
#     if kubectl get cm istio-ca-root-cert -n $VM_NAMESPACE &>/dev/null; then
#         kubectl get cm istio-ca-root-cert -n $VM_NAMESPACE -o jsonpath='{.data.root-cert\.pem}' > "$WORK_DIR/vm-files/root-cert.pem"
#     else
#         # Fallback to istio-system namespace
#         kubectl get cm istio-ca-root-cert -n istio-system -o jsonpath='{.data.root-cert\.pem}' > "$WORK_DIR/vm-files/root-cert.pem"
#     fi
    
#     # Store certificate in certificates directory
#     cp "$WORK_DIR/vm-files/root-cert.pem" "$WORK_DIR/certificates/"
    
#     # Generate the Istio token
#     generate_istio_token
    
#     # Get cluster discovery address with Azure-specific configuration
#     local istiod_ip=$(kubectl get svc istiod -n istio-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
#     if [ -z "$istiod_ip" ]; then
#         print_error "Could not get istiod service IP"
#         exit 1
#     fi
    
#     DISCOVERY_ADDRESS="${istiod_ip}:15012"
    
#     # Create cluster environment file with Azure networking considerations
#     cat > "$WORK_DIR/vm-files/cluster.env" <<EOF
# # Azure AKS + Istio VM Configuration
# ISTIO_SERVICE_CIDR=cluster.local
# ISTIO_INBOUND_PORTS=8080,15020,15021
# ISTIO_LOCAL_EXCLUDE_PORTS=22,15090,15021,15020,443,80
# PILOT_DISCOVERY_ADDRESS=$DISCOVERY_ADDRESS
# ISTIO_PILOT_PORT=15010
# ISTIO_CP_AUTH=MUTUAL_TLS
# PILOT_ENABLE_WORKLOAD_ENTRY_AUTOREGISTRATION=true

# # Azure VM specific settings
# AZURE_METADATA_ENDPOINT=http://169.254.169.254/metadata/instance?api-version=2021-02-01
# AZURE_VM_SCALE_SET=false

# # Service mesh settings
# SERVICE_ACCOUNT=$SERVICE_ACCOUNT
# NAMESPACE=$VM_NAMESPACE
# WORKLOAD_GROUP=$VM_APP
# EOF

#     # Create enhanced mesh configuration for Azure
#     cat > "$WORK_DIR/vm-files/mesh.yaml" <<EOF
# # Istio Mesh Configuration for Azure VMs
# defaultConfig:
#   discoveryAddress: istiod.istio-system.svc:15012
#   proxyStatsMatcher:
#     inclusionRegexps:
#     - ".*outlier_detection.*"
#     - ".*circuit_breakers.*"
#     - ".*upstream_rq_retry.*"
#     - ".*_cx_.*"
#     - ".*azure.*"
#   proxyMetadata:
#     TRUST_DOMAIN: cluster.local
#     PILOT_ENABLE_WORKLOAD_ENTRY_AUTOREGISTRATION: true
#     PILOT_ENABLE_IP_AUTOALLOCATE: true
#     AZURE_METADATA_AVAILABLE: true
#   holdApplicationUntilProxyStarts: true
#   statusPort: 15020
#   proxyAdminPort: 15000
# defaultProviders:
#   metrics:
#   - prometheus
#   tracing:
#   - jaeger
#   accessLogging:
#   - envoy
# extensionProviders:
# - name: prometheus
#   prometheus:
#     configOverride:
#       metric_relabeling_configs:
#       - source_labels: [__name__]
#         regex: "istio_.*"
#         target_label: "azure_workload"
#         replacement: "vm"
# - name: jaeger
#   jaeger:
#     service: jaeger.istio-system.svc.cluster.local
#     port: 14250
# - name: envoy
#   envoy: {}
# EOF

    # Copy scripts if they exist
    print_status "Preparing VM setup script..."
    
    cp "$SCRIPT_DIR/vm-scripts/setup-vm-mesh.sh" "$WORK_DIR/vm-files/"
    
    print_status "✓ VM files generated: $WORK_DIR/vm-files/"
    print_status "Files: hosts, root-cert.pem, istio-token, cluster.env, mesh.yaml, setup-vm-mesh.sh"
}

# Copy files to VM
copy_files_to_vm() {
    print_status "Copying workload setup files to VM from local workspace..."
    
    # Ensure remote directory exists
    ssh -o StrictHostKeyChecking=no azureuser@$VM_IP 'mkdir -p /tmp/vm-files'
    
    # Copy all files from vm-files directory
    if scp -r -o StrictHostKeyChecking=no "$WORK_DIR/vm-files/"* azureuser@$VM_IP:/tmp/vm-files/; then
        print_status "✓ Files copied successfully to VM"
    else
        print_error "Failed to copy files to VM"
        exit 1
    fi
}

# Run VM setup
run_vm_setup() {
    print_status "Setting up VM as mesh workload..."
    
    # Run the setup script on the VM with proper error handling
    if ssh -o StrictHostKeyChecking=no azureuser@$VM_IP 'bash /tmp/vm-files/setup-vm-mesh.sh'; then
        print_status "✓ VM mesh setup completed successfully"
    else
        print_error "VM mesh setup failed"
        exit 1
    fi
}

# Main function with VM IP support
main() {
    print_status "Starting VM mesh integration setup..."
       
    get_vm_ip
    setup_cluster_resources
    apply_vm_config
    generate_vm_files
    copy_files_to_vm
    run_vm_setup
    
    print_status "✅ VM mesh integration completed!"
}

# Run main function
main "$@"
