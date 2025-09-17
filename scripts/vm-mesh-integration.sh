#!/bin/bash

# VM Mesh Integration Script
# This script configures the VM to be part of the Istio mesh
# Uses local workspace and accepts VM_IP as parameter to avoid double execution

set -e

# Shared configuration variables
RESOURCE_GROUP="istio-playground-rg"
CLUSTER_NAME="istio-aks-cluster"
VM_NAME="istio-vm"
VM_NAMESPACE="vm-workloads"
VM_APP="vm-web-service"

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use local workspace (can be overridden by environment variable)
WORK_DIR="$SCRIPT_DIR/../workspace/vm-mesh-setup"
SERVICE_ACCOUNT="vm-workload"
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
    
    # Wait for ServiceAccount to be ready
    print_status "Waiting for ServiceAccount to be ready..."
    kubectl wait --for=condition=Ready serviceaccount/$SERVICE_ACCOUNT -n $VM_NAMESPACE --timeout=30s || true
    
    # Verify ServiceAccount exists before proceeding
    if ! kubectl get serviceaccount $SERVICE_ACCOUNT -n $VM_NAMESPACE &> /dev/null; then
        print_error "ServiceAccount $SERVICE_ACCOUNT not found in namespace $VM_NAMESPACE"
        exit 1
    fi
    print_status "✓ ServiceAccount $SERVICE_ACCOUNT is ready"
    
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
    periodSeconds: 5
    initialDelaySeconds: 1
    httpGet:
      port: 8080
      path: /ready
EOF

    kubectl apply -f "$WORK_DIR/vm-files/workloadgroup.yaml"
    
    # Verify WorkloadGroup was created successfully
    if kubectl get workloadgroup $VM_APP -n $VM_NAMESPACE &> /dev/null; then
        print_status "✓ WorkloadGroup $VM_APP created successfully in namespace $VM_NAMESPACE"
        
        # Validate ServiceAccount reference in WorkloadGroup
        local sa_in_wg=$(kubectl get workloadgroup $VM_APP -n $VM_NAMESPACE -o jsonpath='{.spec.template.serviceAccount}' 2>/dev/null || echo "")
        if [ "$sa_in_wg" = "$SERVICE_ACCOUNT" ]; then
            print_status "✓ WorkloadGroup correctly references ServiceAccount: $SERVICE_ACCOUNT"
        else
            print_warning "⚠ WorkloadGroup ServiceAccount reference mismatch: expected $SERVICE_ACCOUNT, found '$sa_in_wg'"
        fi
    else
        print_error "Failed to create WorkloadGroup $VM_APP"
        exit 1
    fi
    
    # Create AuthorizationPolicy for VM workload
    print_status "Creating AuthorizationPolicy for VM workload..."
    kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: vm-workload-policy
  namespace: $VM_NAMESPACE
spec:
  selector:
    matchLabels:
      app: $VM_APP
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/$VM_NAMESPACE/sa/$SERVICE_ACCOUNT"]
    - source:
        principals: ["cluster.local/ns/mesh-test/sa/sleep"]
    - source:
        principals: ["cluster.local/ns/helloworld/sa/default"]
  - to:
    - operation:
        methods: ["GET", "POST", "PUT", "DELETE"]
        paths: ["/*"]
EOF
    
    # Create AuthorizationPolicy to allow VM workload to access other services
    kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: vm-outbound-policy
  namespace: $VM_NAMESPACE
spec:
  selector:
    matchLabels:
      app: $VM_APP
  action: ALLOW
  rules:
  - to:
    - operation:
        methods: ["GET", "POST"]
EOF
    
    print_status "✓ AuthorizationPolicy configurations created"
    
    # Update HelloWorld AuthorizationPolicy to include VM workload access
    print_status "Updating HelloWorld AuthorizationPolicy to include VM access..."
    kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: helloworld-policy
  namespace: helloworld
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/helloworld/sa/default"]
    - source:
        principals: ["cluster.local/ns/mesh-test/sa/sleep"]
    - source:
        principals: ["cluster.local/ns/vm-workloads/sa/vm-workload"]
    - source:
        namespaces: ["istio-system"]
  - to:
    - operation:
        methods: ["GET", "POST", "HEAD"]
        paths: ["/hello", "/"]
EOF
    
    print_status "✓ HelloWorld AuthorizationPolicy updated with VM access"

    print_status "✓ Cluster resources configured with Azure optimizations"
}

# Apply VM configuration files with immediate VM IP
apply_vm_config() {
    print_status "Applying VM configuration..."

    # Service configuration
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $VM_APP
  namespace: $VM_NAMESPACE
  labels:
    app: $VM_APP
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
  gateways:
  - mesh
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
    # TODO: The WorkloadEntry is created but with a different name, i.e.: vm-web-service-10.0.0.4-vm-network
    if ! kubectl get workloadentry -n $VM_NAMESPACE $VM_APP-vm &> /dev/null; then
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
    else 
      print_status "WorkloadEntry $VM_APP-vm already exists, skipping creation."
    fi

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

# Generate comprehensive VM files with Azure optimizations
generate_vm_files() {
    print_status "Generating comprehensive VM files for Azure deployment..."

    # Get istiod service ingress IP
    local istiod_ip=$(kubectl get svc istiod -n istio-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -z "$istiod_ip" ]; then
        print_error "Could not get istiod service IP"
        exit 1
    fi

    istioctl x workload entry configure -f "$WORK_DIR/vm-files/workloadgroup.yaml" -o "$WORK_DIR/vm-files" --clusterID "${CLUSTER_NAME}" --autoregister
    rm -f "$WORK_DIR/vm-files/workloadgroup.yaml"

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
