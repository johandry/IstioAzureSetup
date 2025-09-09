#!/bin/bash

# Enhanced Azure AKS + Istio Setup Script with Full Parameter Support
# This script provides comprehensive management for AKS, Istio, and VM mesh integration
# The script is idempotent and can be run multiple times safely

# Enable error handling but allow some commands to fail gracefully
set -e

# Configuration variables
LOCATION="westus"
NODE_COUNT=3
NODE_VM_SIZE="Standard_L8s_v3"
CLUSTER_NETWORK="kube-network" # Multi-Network
VM_SIZE="Standard_B2s"

# Shared configuration variables
RESOURCE_GROUP="istio-playground-rg"
CLUSTER_NAME="istio-aks-cluster"
VM_NAME="istio-vm"

# Local workspace directories (keep everything in current directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$SCRIPT_DIR/workspace"
ISTIO_DIR="$WORKSPACE_DIR/istio-installation"
VM_MESH_DIR="$WORKSPACE_DIR/vm-mesh-setup"
CERTS_DIR="$WORKSPACE_DIR/certs"
CONFIGS_DIR="$WORKSPACE_DIR/configs"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YIGHLIGHT}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

show_usage() {
    echo "Azure AKS + Istio Management Script"
    echo ""
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "COMMANDS:"
    echo "  setup               Complete AKS and Istio setup (default)"
    echo "  setup-vm-mesh       Setup VM mesh integration"
    echo "  deploy-samples      Deploy Istio sample applications"
    echo "  deploy-mesh-test    Deploy mesh testing applications"
    echo "  test-mesh           Test VM mesh integration"
    echo "  port-forward [stop] Forward ports for services and dashboards"
    echo "  status              Show current deployment status"
    echo "  cleanup [local]     Clean up all Azure resources or local workspace"
    echo "  uninstall-istio     Uninstall Istio from the cluster"
    echo "  help                Show this help message"
    echo ""
    echo "OPTIONS:"
    echo "  --resource-group NAME    Override resource group name"
    echo "  --cluster-name NAME      Override cluster name"
    echo "  --vm-name NAME           Override VM name"
    echo "  --location LOCATION      Override Azure location"
    echo ""
    echo "EXAMPLES:"
    echo "  $0                     # Complete setup"
    echo "  $0 setup               # Complete setup"
    echo "  $0 setup-vm-mesh       # Setup VM mesh only"
    echo "  $0 deploy-samples      # Deploy sample apps"
    echo "  $0 port-forward        # Forward ports for services"
    echo "  $0 port-forward stop   # Stop port forwarding"
    echo "  $0 status              # Check status"
    echo "  $0 cleanup             # Clean everything"
    echo ""
}

# Parse command line arguments
parse_arguments() {
    COMMAND="setup"  # Default command
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            setup|setup-vm-mesh|deploy-samples|deploy-mesh-test|test-mesh|port-forward|status|cleanup|uninstall-istio|help)
                COMMAND="$1"
                if [ "$1" == "cleanup" ] && [ "$2" == "local" ]; then
                    COMMAND="cleanup-local"
                    shift
                fi
                if [ "$1" == "port-forward" ] && [ "$2" == "stop" ]; then
                    COMMAND="stop-port-forward"
                    shift
                fi
                ;;
            --resource-group)
                RESOURCE_GROUP="$2"
                shift
                ;;
            --cluster-name)
                CLUSTER_NAME="$2"
                shift
                ;;
            --vm-name)
                VM_NAME="$2"
                shift
                ;;
            --location)
                LOCATION="$2"
                shift
                ;;
            -h|--help)
                COMMAND="help"
                ;;
            *)
                print_error "Unknown parameter: $1"
                show_usage
                exit 1
                ;;
        esac
        shift
    done
}

# Show comprehensive status
show_status() {
    print_header "AZURE ISTIO DEPLOYMENT STATUS"
    
    echo ""
    echo "Configuration:"
    echo "  Resource Group: $RESOURCE_GROUP"
    echo "  Cluster Name: $CLUSTER_NAME"
    echo "  VM Name: $VM_NAME"
    echo "  Location: $LOCATION"
    echo "  Workspace: $WORKSPACE_DIR"
    echo ""
    
    # Check Azure resources
    echo "Azure Resources:"
    if az group show --name $RESOURCE_GROUP &> /dev/null; then
        echo "  ✓ Resource Group: $RESOURCE_GROUP exists"
    else
        echo "  ✗ Resource Group: $RESOURCE_GROUP does not exist"
    fi
    
    if az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME &> /dev/null; then
        CLUSTER_STATE=$(az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --query "powerState.code" -o tsv)
        echo "  ✓ AKS Cluster: $CLUSTER_NAME ($CLUSTER_STATE)"
    else
        echo "  ✗ AKS Cluster: $CLUSTER_NAME does not exist"
    fi
    
    if az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME &> /dev/null; then
        VM_STATE=$(az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME --show-details --query "powerState" -o tsv)
        VM_IP=$(az vm show -d -g $RESOURCE_GROUP -n $VM_NAME --query publicIps -o tsv)
        echo "  ✓ VM: $VM_NAME ($VM_STATE) - IP: $VM_IP"
    else
        echo "  ✗ VM: $VM_NAME does not exist"
    fi
    
    echo ""
    
    # Check Kubernetes resources
    echo "Kubernetes Resources:"
    if kubectl get namespace istio-system &> /dev/null 2>&1; then
        echo "  ✓ Istio namespace exists"
        
        if kubectl get deployment istiod -n istio-system &> /dev/null 2>&1; then
            ISTIOD_STATUS=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null)
            echo "  ✓ Istiod deployment: $ISTIOD_STATUS ready"
        else
            echo "  ✗ Istiod deployment not found"
        fi
        
        GATEWAY_IP=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "Not assigned")
        echo "  ✓ Ingress Gateway IP: $GATEWAY_IP"
    else
        echo "  ✗ Istio not installed"
    fi
    
    # Check VM mesh resources
    if kubectl get namespace vm-workloads &> /dev/null 2>&1; then
        echo "  ✓ VM workloads namespace exists"
        
        WORKLOAD_ENTRIES=$(kubectl get workloadentry -n vm-workloads --no-headers 2>/dev/null | wc -l)
        echo "  ✓ WorkloadEntries: $WORKLOAD_ENTRIES"
        
        VM_SERVICES=$(kubectl get svc -n vm-workloads --no-headers 2>/dev/null | wc -l)
        echo "  ✓ VM Services: $VM_SERVICES"
    else
        echo "  ✗ VM workloads namespace not found"
    fi
    
    echo ""
}

# Create local workspace structure
create_local_workspace() {
    print_status "Creating local workspace structure..."
    
    # Create all necessary directories in the current workspace
    mkdir -p "$WORKSPACE_DIR"
    mkdir -p "$ISTIO_DIR"
    mkdir -p "$VM_MESH_DIR"
    mkdir -p "$CERTS_DIR"
    mkdir -p "$CONFIGS_DIR"
    mkdir -p "$VM_MESH_DIR/vm-files"
    mkdir -p "$VM_MESH_DIR/cluster-configs"
    mkdir -p "$VM_MESH_DIR/certificates"
    
    # Create symlinks if needed for system tools
    if [ ! -L "/tmp/vm-mesh-setup" ]; then
        ln -sf "$VM_MESH_DIR" "/tmp/vm-mesh-setup" 2>/dev/null || print_warning "Could not create symlink to /tmp"
    fi
    
    print_status "Workspace created at: $WORKSPACE_DIR"
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    if ! command -v az &> /dev/null; then
        print_error "Azure CLI is not installed. Please install it first."
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed. Please install it first."
        exit 1
    fi
    
    check_azure_login
   
    print_status "Prerequisites check passed!"
}

# Check existing Azure resources to avoid conflicts
check_existing_resources() {
    print_status "Checking existing Azure resources..."
    
    # Get current subscription info
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
    
    print_status "Using Azure subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
    
    # Check resource group existence
    if az group show --name $RESOURCE_GROUP &> /dev/null; then
        print_status "Resource group '$RESOURCE_GROUP' exists"
        
        # Check for existing AKS cluster
        if az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME &> /dev/null; then
            CLUSTER_STATE=$(az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --query "powerState.code" -o tsv)
            print_status "AKS cluster '$CLUSTER_NAME' exists (State: $CLUSTER_STATE)"
            
            # If cluster exists but is stopped, we'll start it later
            if [ "$CLUSTER_STATE" != "Running" ]; then
                print_warning "Cluster is not running - will be started during setup"
            fi
        else
            print_status "AKS cluster '$CLUSTER_NAME' does not exist - will be created"
        fi
        
        # Check for existing VM
        if az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME &> /dev/null; then
            VM_STATE=$(az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME --show-details --query "powerState" -o tsv)
            print_status "VM '$VM_NAME' exists (State: $VM_STATE)"
            
            # If VM exists but is stopped, we'll start it later
            if [ "$VM_STATE" != "VM running" ]; then
                print_warning "VM is not running - will be started during setup"
            fi
        else
            print_status "VM '$VM_NAME' does not exist - will be created"
        fi
    else
        print_status "Resource group '$RESOURCE_GROUP' does not exist - will be created"
    fi
    
    # Validate Azure location
    if ! az account list-locations --query "[?name=='$LOCATION']" -o tsv | grep -q "$LOCATION"; then
        print_error "Invalid Azure location: $LOCATION"
        print_status "Available locations:"
        az account list-locations --query "[].name" -o tsv | sort
        exit 1
    fi
    
    print_status "✓ Resource validation completed"
}

# Create resource group
create_resource_group() {
    print_status "Creating resource group: $RESOURCE_GROUP"
    
    if az group show --name $RESOURCE_GROUP &> /dev/null; then
        print_status "Resource group $RESOURCE_GROUP already exists, skipping creation"
    else
        az group create --name $RESOURCE_GROUP --location $LOCATION
        print_status "Resource group $RESOURCE_GROUP created successfully"
    fi
}

# Create AKS cluster
create_aks_cluster() {
    print_status "Creating AKS cluster: $CLUSTER_NAME"
    
    if az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME &> /dev/null; then
        print_status "AKS cluster $CLUSTER_NAME already exists, skipping creation"
        
        # Check if cluster is running
        CLUSTER_STATE=$(az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --query "powerState.code" -o tsv)
        if [ "$CLUSTER_STATE" != "Running" ]; then
            print_warning "Cluster exists but is not running. State: $CLUSTER_STATE"
            print_status "Starting cluster..."
            az aks start --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME
        fi
    else
        print_warning "This may take 10-15 minutes..."
        az aks create \
            --resource-group $RESOURCE_GROUP \
            --name $CLUSTER_NAME \
            --node-count $NODE_COUNT \
            --node-vm-size $NODE_VM_SIZE \
            --enable-addons monitoring \
            --generate-ssh-keys \
            --enable-managed-identity \
            --network-plugin azure \
            --service-cidr 10.0.0.0/16 \
            --dns-service-ip 10.0.0.10 \
            --tier free
        print_status "AKS cluster $CLUSTER_NAME created successfully"
    fi
}

# Get AKS credentials
get_aks_credentials() {
    print_status "Getting AKS credentials..."
    
    # Always get credentials to ensure they're current
    az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --overwrite-existing
    
    # Verify connection
    if kubectl cluster-info &> /dev/null; then
        print_status "Successfully connected to cluster"
    else
        print_error "Failed to connect to cluster"
        exit 1
    fi
}

# Create VM
create_vm() {
    print_status "Creating VM: $VM_NAME"
    
    if az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME &> /dev/null; then
        print_status "VM $VM_NAME already exists, skipping creation"
        
        # Check if VM is running
        VM_STATE=$(az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME  --show-details --query "powerState" -o tsv)
        if [ "$VM_STATE" != "VM running" ]; then
            print_warning "VM exists but is not running. State: $VM_STATE"
            print_status "Starting VM..."
            az vm start --resource-group $RESOURCE_GROUP --name $VM_NAME
        fi
    else
        az vm create \
            --resource-group $RESOURCE_GROUP \
            --name $VM_NAME \
            --image Ubuntu2204 \
            --size $VM_SIZE \
            --admin-username azureuser \
            --generate-ssh-keys \
            --public-ip-sku Standard 
        print_status "VM $VM_NAME created successfully"
    fi
    
    # Explicitly create NSG rules for required ports (visible in Azure portal)
    # Get NIC name associated with the VM
    NIC_NAME=$(az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME --query 'networkProfile.networkInterfaces[0].id' -o tsv | awk -F/ '{print $NF}')
    # Get NSG name from NIC
    NSG_NAME=$(az network nic show --resource-group $RESOURCE_GROUP --name "$NIC_NAME" --query 'networkSecurityGroup.id' -o tsv | awk -F/ '{print $NF}')
    if [ -z "$NSG_NAME" ]; then
        NSG_NAME=$(az network nsg list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
    fi

    # Open SSH port 22

    az network nsg rule create --resource-group $RESOURCE_GROUP --nsg-name "$NSG_NAME" --name Allow-SSH --priority 1001 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes '*' --destination-port-ranges 22 --destination-address-prefixes '*' --description "Allow SSH" &> /dev/null

    az network nsg rule create --resource-group $RESOURCE_GROUP --nsg-name "$NSG_NAME" --name Allow-VMWeb8080 --priority 1002 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes '*' --destination-port-ranges 8080 --destination-address-prefixes '*' --description "Allow VM Web Service" &> /dev/null

    az network nsg rule create --resource-group $RESOURCE_GROUP --nsg-name "$NSG_NAME" --name Allow-HTTPS443 --priority 1003 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes '*' --destination-port-ranges 443 --destination-address-prefixes '*' --description "Allow HTTPS" &> /dev/null

    az network nsg rule create --resource-group $RESOURCE_GROUP --nsg-name "$NSG_NAME" --name Allow-IstioMesh --priority 1004 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes '*' --destination-port-ranges 15000-15090 --destination-address-prefixes '*' --description "Allow Istio Mesh Ports" &> /dev/null

    print_status "NSG rules created for ports 22, 8080, 443, 15000-15090 on VM ($NSG_NAME)"
}

# Install Istio on the cluster
install_istio() {
    print_status "Installing Istio on AKS cluster..."
    
    # Check if Istio is already installed
    if kubectl get namespace istio-system &> /dev/null && kubectl get deployment istiod -n istio-system &> /dev/null; then
        print_status "Istio is already installed, checking status..."
        
        # Check if istiod is ready
        local ready_replicas=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        local desired_replicas=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.status.replicas}' 2>/dev/null || echo "1")
        
        if [ "$ready_replicas" -ge "1" ] && [ "$ready_replicas" = "$desired_replicas" ]; then
            print_status "Istio is installed and ready ($ready_replicas/$desired_replicas replicas)"
        else
            print_warning "Istio is installed but not ready ($ready_replicas/$desired_replicas replicas), waiting..."
            kubectl wait --for=condition=available --timeout=300s deployment/istiod -n istio-system
        fi
    else
        # Download Istio to local workspace
        if [ ! -d "$ISTIO_DIR" ] || [ ! -f "$ISTIO_DIR/bin/istioctl" ]; then
            print_status "Downloading Istio to workspace directory..."
            
            # Ensure workspace directory exists
            mkdir -p "$WORKSPACE_DIR"
            cd "$WORKSPACE_DIR"
            
            # Download latest Istio
            curl -L https://istio.io/downloadIstio | sh -
            
            # Move to our organized structure and preserve samples
            local istio_download_dir=$(find . -maxdepth 1 -name "istio-*" -type d | head -1)
            
            if [ -n "$istio_download_dir" ] && [ -d "$istio_download_dir" ]; then
                print_status "Found Istio download directory: $istio_download_dir"
                
                # Remove old installation if it exists
                if [ -d "istio-installation" ]; then
                    print_status "Removing existing Istio installation..."
                    rm -rf istio-installation
                fi
                
                # Move the downloaded directory to our standard name
                mv "$istio_download_dir" istio-installation
                
                print_status "Istio downloaded to: $ISTIO_DIR"
            else
                print_error "Failed to find Istio download directory"
                exit 1
            fi
            
            cd "$SCRIPT_DIR"
        else
            print_status "Istio already exists in workspace at: $ISTIO_DIR"
        fi
        
        # Add istioctl to PATH for this session
        export PATH="$ISTIO_DIR/bin:$PATH"
        
        # Verify istioctl is working
        if ! command -v istioctl &> /dev/null; then
            print_error "istioctl not found in PATH after download"
            print_status "Expected location: $ISTIO_DIR/bin/istioctl"
            print_status "Current PATH: $PATH"
            if [ -f "$ISTIO_DIR/bin/istioctl" ]; then
                print_status "istioctl file exists, checking permissions..."
                ls -la "$ISTIO_DIR/bin/istioctl"
            fi
            exit 1
        fi
        
        print_status "Using istioctl from: $(which istioctl)"
        
        # Get Istio version for logging
        local istio_version=$(istioctl version 2>/dev/null | grep "client version" | cut -d':' -f2 | tr -d ' ' || echo "unknown")
        print_status "Installing Istio version: $istio_version"

        # Install Istio with demo profile to avoid installing CRDs or other components
        print_status "Installing Istio with demo profile..."
        cat <<EOF | istioctl install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio
  namespace: istio-system
spec:
  profile: demo
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: "${CLUSTER_NAME}"
      network: "${CLUSTER_NETWORK}"
EOF

        print_status "Deploy the east-west (internal) gateway..."
        cat <<EOF | istioctl install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: eastwest
spec:
  revision: ""
  profile: empty
  components:
    ingressGateways:
      - name: istio-eastwestgateway
        label:
          istio: eastwestgateway
          app: istio-eastwestgateway
          topology.istio.io/network: "${CLUSTER_NETWORK}"
        enabled: true
        k8s:
          env:
            # traffic through this gateway should be routed inside the network
            - name: ISTIO_META_REQUESTED_NETWORK_VIEW
              value: "${CLUSTER_NETWORK}"
          service:
            ports:
              - name: status-port
                port: 15021
                targetPort: 15021
              - name: tls
                port: 15443
                targetPort: 15443
              - name: tls-istiod
                port: 15012
                targetPort: 15012
              - name: tls-webhook
                port: 15017
                targetPort: 15017
  values:
    gateways:
      istio-ingressgateway:
        injectionTemplate: gateway
    global:
      network: "${CLUSTER_NETWORK}"
EOF

        print_status "Exposing the control plane..."
        # From samples/multicluster/expose-istiod.yaml
        kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: istiod-gateway
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        name: tls-istiod
        number: 15012
        protocol: tls
      tls:
        mode: PASSTHROUGH        
      hosts:
        - "*"
    - port:
        name: tls-istiodwebhook
        number: 15017
        protocol: tls
      tls:
        mode: PASSTHROUGH          
      hosts:
        - "*"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: istiod-vs
spec:
  hosts:
  - "*"
  gateways:
  - istiod-gateway
  tls:
  - match:
    - port: 15012
      sniHosts:
      - "*"
    route:
    - destination:
        host: istiod.istio-system.svc.cluster.local
        port:
          number: 15012
  - match:
    - port: 15017
      sniHosts:
      - "*"
    route:
    - destination:
        host: istiod.istio-system.svc.cluster.local
        port:
          number: 443
EOF

  
        print_status "Exposing cluster services..."
        # From samples/multicluster/expose-services.yaml
        kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: cross-network-gateway
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        number: 15443
        name: tls
        protocol: TLS
      tls:
        mode: AUTO_PASSTHROUGH
      hosts:
        - "*.local"
EOF

        # label the istio-system namespace with the cluster network
        kubectl label namespace istio-system topology.istio.io/network="${CLUSTER_NETWORK}"
        
        print_status "Waiting for Istio components to be ready..."
        kubectl wait --for=condition=available --timeout=300s deployment/istiod -n istio-system
        
        print_status "Istio installed successfully on AKS cluster"
    fi
    
    # Label default namespace for Istio injection (idempotent)
    kubectl label namespace default istio-injection=enabled --overwrite
    
    # Install Istio addons from workspace samples directory
    if [ -d "$ISTIO_DIR/samples/addons" ]; then
        print_status "Installing Istio addons from workspace samples..."
        
        # Apply addons with error handling
        for addon in "$ISTIO_DIR/samples/addons"/*.yaml; do
            if [ -f "$addon" ]; then
                local addon_name=$(basename "$addon" .yaml)
                print_status "Installing addon: $addon_name"
                kubectl apply -f "$addon" || print_warning "Failed to install $addon_name addon"
            fi
        done
        
        # Wait for addon deployments to be ready with timeout handling
        print_status "Waiting for addon deployments to be ready..."
        
        # Check each addon separately to avoid timeout issues
        if kubectl get deployment kiali -n istio-system &> /dev/null; then
            kubectl wait --for=condition=available --timeout=180s deployment/kiali -n istio-system || print_warning "Kiali not ready within timeout"
        fi
        
        if kubectl get deployment grafana -n istio-system &> /dev/null; then
            kubectl wait --for=condition=available --timeout=180s deployment/grafana -n istio-system || print_warning "Grafana not ready within timeout"
        fi
        
        if kubectl get deployment jaeger -n istio-system &> /dev/null; then
            kubectl wait --for=condition=available --timeout=180s deployment/jaeger -n istio-system || print_warning "Jaeger not ready within timeout"
        fi
        
        print_status "Istio addons installed from workspace samples"
    else
        print_warning "Addons directory not found: $ISTIO_DIR/samples/addons"
    fi
}

# Deploy HelloWorld sample application with Azure optimized gateway
deploy_helloworld_sample() {
    print_header "DEPLOYING HELLOWORLD SAMPLE APPLICATION"


    kubectl create namespace helloworld --dry-run=client -o yaml | kubectl apply -f - # (idempotent operation)
     # Label helloworld namespace for Istio injection (idempotent)
    kubectl label namespace helloworld istio-injection=enabled --overwrite

    print_status "Deploying HelloWorld from Istio samples..."
    kubectl apply -n helloworld -f "$ISTIO_DIR/samples/helloworld/helloworld.yaml"

    # Wait for deployments to be ready
    print_status "Waiting for HelloWorld deployments to be ready..."
    kubectl wait --for=condition=available --timeout=300s -n helloworld deployment/helloworld-v1  || print_warning "HelloWorld-v1 not ready within timeout"
    kubectl wait --for=condition=available --timeout=300s -n helloworld deployment/helloworld-v2  || print_warning "HelloWorld-v2 not ready within timeout"
    print_status "HelloWorld application deployed. The service 'helloworld' and deployments 'helloworld-v1' and 'helloworld-v2' are now running."
    print_status "HelloWorld is now accessible at http://<GATEWAY_IP>/hello:"

    # Create Gateway and VirtualService for HelloWorld
    print_status "Configuring HelloWorld gateway and routing..."
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: helloworld-gateway
  namespace: helloworld
  labels:
    app: helloworld
    environment: development
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: helloworld
  namespace: helloworld
  labels:
    app: helloworld
    environment: development
spec:
  hosts:
  - "*"
  gateways:
  - helloworld-gateway
  - istio-system/istio-gateway
  http:
  - match:
    - uri:
        prefix: /hello
    route:
    - destination:
        host: helloworld.default.svc.cluster.local
        port:
          number: 5000
    timeout: 30s
    retries:
      attempts: 3
      perTryTimeout: 10s
  - match:
    - uri:
        exact: /
    redirect:
      uri: /hello
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: helloworld
  namespace: helloworld
  labels:
    app: helloworld
spec:
  host: helloworld.default.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 10
      http:
        http1MaxPendingRequests: 10
        maxRequestsPerConnection: 2
    loadBalancer:
      simple: ROUND_ROBIN
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 30s
      baseEjectionTime: 30s
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
EOF
    
    print_status "✅ HelloWorld sample application deployed successfully!"
    
    # Show access information
    local gateway_ip=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    if [ "$gateway_ip" != "pending" ] && [ -n "$gateway_ip" ]; then
        print_status "🌐 Access HelloWorld at: http://$gateway_ip/hello"
        print_status "🔄 Refresh the page multiple times to see traffic distribution between v1 and v2"
    else
        print_status "⏳ Gateway IP assignment pending. Check status with: kubectl get svc istio-ingressgateway -n istio-system"
    fi
}

# Create TLS certificate for HTTPS (store in local certs directory)
setup_tls_certificate() {
    print_status "Setting up TLS certificate for gateway..."
    
    if kubectl get secret istio-tls-secret -n istio-system &> /dev/null; then
        print_status "TLS certificate already exists"
        return 0
    fi
    
    # Generate certificates in local certs directory
    CERT_FILE="$CERTS_DIR/istio-gateway.crt"
    KEY_FILE="$CERTS_DIR/istio-gateway.key"
    
    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        print_status "Generating TLS certificates in local workspace..."
        
        # Create self-signed certificate for development
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -subj "/CN=istio-gateway.local/O=istio-gateway" \
            -keyout "$KEY_FILE" \
            -out "$CERT_FILE"
        
        print_status "Certificates generated in: $CERTS_DIR"
    fi
    
    # Create Kubernetes secret from local files
    kubectl create secret tls istio-tls-secret \
        --cert="$CERT_FILE" \
        --key="$KEY_FILE" \
        -n istio-system 2>/dev/null || print_warning "TLS secret creation failed, HTTPS will not work"
    
    print_status "TLS certificate configured from local files"
}

# Configure VM for Istio mesh integration (not as bastion)
configure_vm() {
    print_status "Configuring VM for Istio mesh integration..."
    
    VM_IP=$(az vm show -d -g $RESOURCE_GROUP -n $VM_NAME --query publicIps -o tsv)
    
    if [ -z "$VM_IP" ]; then
        print_error "Could not get VM IP address"
        return 1
    fi
    
    print_status "VM IP: $VM_IP"
    
    # Store VM IP in local config for reference
    echo "VM_IP=$VM_IP" > "$CONFIGS_DIR/vm-config.env"
    echo "VM_NAME=$VM_NAME" >> "$CONFIGS_DIR/vm-config.env"
    echo "RESOURCE_GROUP=$RESOURCE_GROUP" >> "$CONFIGS_DIR/vm-config.env"
    
    # Install basic packages on VM for mesh integration
    print_status "Installing basic packages on VM..."
    ssh -o StrictHostKeyChecking=no azureuser@$VM_IP 'sudo apt update && sudo apt install -y curl python3 python3-pip'
    
    # Install kubectl
    stable_version=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    print_status "Installing kubectl..."
    ssh -o StrictHostKeyChecking=no azureuser@$VM_IP "curl -LO \"https://dl.k8s.io/release/$stable_version/bin/linux/amd64/kubectl\" && chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
    kubectl_version=$(ssh -o StrictHostKeyChecking=no azureuser@$VM_IP "kubectl version | grep 'Client Version' | awk '{print \$3}'")
    if [ "$kubectl_version" != "$stable_version" ]; then
        print_warning "kubectl version mismatch: expected $stable_version, got $kubectl_version"
    else
        print_status "kubectl $kubectl_version installed successfully"
    fi

    # Install istioctl
    print_status "Installing istioctl..."
    ssh -o StrictHostKeyChecking=no azureuser@$VM_IP "curl -L https://istio.io/downloadIstio | sh - && sudo mv istio-*/bin/istioctl /usr/local/bin/ && rm -rf istio-*"
    istioctl_version=$(ssh -o StrictHostKeyChecking=no azureuser@$VM_IP "istioctl version | grep 'client version' | awk '{print \$3}'")
    if [ -z "$istioctl_version" ]; then
        print_warning "istioctl version not found"
    else
        print_status "istioctl v$istioctl_version installed successfully"
    fi

    print_status "VM configured for mesh integration"
}

# Test HelloWorld connectivity and traffic distribution using port forwarding
test_helloworld_connectivity() {
    print_status "Testing HelloWorld connectivity and traffic distribution via port forwarding..."
    
    # Check if HelloWorld service exists
    if ! kubectl get svc helloworld -n helloworld &> /dev/null; then
        print_warning "HelloWorld service not found in helloworld namespace. Skipping connectivity test."
        return 0
    fi
    
    # Find an available port for temporary port forwarding
    local test_port=8090
    while lsof -Pi :$test_port -sTCP:LISTEN -t >/dev/null 2>&1; do
        test_port=$((test_port + 1))
    done
    
    print_status "Using port $test_port for temporary port forwarding..."
    
    # Start temporary port forwarding in background
    kubectl port-forward -n helloworld svc/helloworld "$test_port:5000" &> /dev/null &
    local port_forward_pid=$!
    
    # Give port forwarding time to establish
    sleep 3
    
    # Verify port forwarding is working
    if ! kill -0 "$port_forward_pid" 2>/dev/null; then
        print_error "Failed to establish port forwarding for HelloWorld service"
        return 1
    fi
    
    print_status "Port forwarding established on localhost:$test_port"
    print_status "Testing HelloWorld service (5 requests)..."
    
    local v1_count=0
    local v2_count=0
    local failed_count=0
    
    for i in {1..5}; do
        local response=$(curl -s --connect-timeout 5 --max-time 10 "http://localhost:$test_port/hello" 2>/dev/null)
        
        if [ -n "$response" ]; then
            if echo "$response" | grep -q "v1"; then
                v1_count=$((v1_count + 1))
                echo "  Request $i: v1 ✓"
            elif echo "$response" | grep -q "v2"; then
                v2_count=$((v2_count + 1))
                echo "  Request $i: v2 ✓"
            else
                echo "  Request $i: Unknown response: $response"
                failed_count=$((failed_count + 1))
            fi
        else
            echo "  Request $i: Failed ✗"
            failed_count=$((failed_count + 1))
        fi
        
        sleep 1
    done
    
    # Clean up port forwarding
    if kill "$port_forward_pid" 2>/dev/null; then
        print_status "Temporary port forwarding stopped"
    else
        print_warning "Failed to stop temporary port forwarding process (PID: $port_forward_pid)"
    fi
    
    echo ""
    print_status "Traffic Distribution Results (via port forwarding):"
    echo "  HelloWorld v1: $v1_count requests"
    echo "  HelloWorld v2: $v2_count requests"
    echo "  Failed: $failed_count requests"
    
    if [ $failed_count -eq 0 ]; then
        print_status "✅ All connectivity tests passed!"
        if [ $v1_count -gt 0 ] && [ $v2_count -gt 0 ]; then
            print_status "✅ Traffic distribution working correctly between versions"
        fi
    else
        print_warning "Some connectivity tests failed. This may be normal during initial deployment."
    fi
}

# Enhanced connection info with local workspace details
get_connection_info() {
    print_status "Getting connection information..."
    
    # Load VM config from local file
    if [ -f "$CONFIGS_DIR/vm-config.env" ]; then
        source "$CONFIGS_DIR/vm-config.env"
    else
        VM_IP=$(az vm show -d -g $RESOURCE_GROUP -n $VM_NAME --query publicIps -o tsv)
    fi
    
    # Load Azure config
    if [ -f "$CONFIGS_DIR/azure-config.env" ]; then
        source "$CONFIGS_DIR/azure-config.env"
    fi
    
    GATEWAY_IP=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "Not assigned")
    GATEWAY_FQDN=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "Not assigned")
    
    echo ""
    echo "========================================="
    echo "SETUP COMPLETED SUCCESSFULLY!"
    echo "========================================="
    echo ""
    echo "🎉 HelloWorld Sample Application Ready!"
    echo ""
    echo "Quick Test Commands:"
    if [ "$GATEWAY_IP" != "Not assigned" ]; then
        echo "  curl http://$GATEWAY_IP/hello                    # Test HelloWorld"
        echo "  for i in {1..10}; do curl http://$GATEWAY_IP/hello; echo; done  # Test load balancing"
    fi
    echo ""
    echo "Local Workspace: $WORKSPACE_DIR"
    echo "  ├── istio-installation/    # Istio binaries, samples, and documentation"
    echo "  │   ├── bin/               # istioctl and other tools"
    echo "  │   ├── samples/           # Istio sample applications and configurations"
    echo "  │   └── manifests/         # Istio installation manifests"
    echo "  ├── vm-mesh-setup/         # VM mesh integration files"
    echo "  ├── certs/                 # TLS certificates"
    echo "  └── configs/               # Configuration files"
    echo ""
    echo "Azure Resources:"
    echo "  AKS Cluster: $CLUSTER_NAME"
    echo "  Resource Group: $RESOURCE_GROUP"
    echo "  VM IP: $VM_IP"
    echo "  Gateway IP: $GATEWAY_IP"
    if [ "$GATEWAY_FQDN" != "Not assigned" ]; then
        echo "  Gateway FQDN: $GATEWAY_FQDN"
    fi
    echo ""
    echo "Sample Applications Access:"
    if [ "$GATEWAY_IP" != "Not assigned" ]; then
        echo "  🌍 HelloWorld App:      http://$GATEWAY_IP/hello"
        echo "  📊 Kiali Dashboard:     http://$GATEWAY_IP/kiali"
        echo "  📈 Grafana Dashboard:   http://$GATEWAY_IP/grafana"
        echo "  🔍 Jaeger Tracing:      http://$GATEWAY_IP/jaeger"
        echo "  🖥️  VM Service:         http://$GATEWAY_IP/vm-service"
        echo "  ❤️  Gateway Health:     http://$GATEWAY_IP/health"
    else
        echo "  ⏳ Gateway IP pending assignment..."
        echo "  📊 Port-forward Kiali:   kubectl port-forward -n istio-system svc/kiali 20001:20001"
        echo "  📈 Port-forward Grafana: kubectl port-forward -n istio-system svc/grafana 3000:3000"
        echo "  🔍 Port-forward Jaeger:  kubectl port-forward -n istio-system svc/jaeger 16686:16686"
    fi
    echo ""
    echo "Configuration Files:"
    echo "  VM Config: $CONFIGS_DIR/vm-config.env"
    echo "  Azure Config: $CONFIGS_DIR/azure-config.env"
    echo "  TLS Certs: $CERTS_DIR/"
    echo "  Mesh Setup: $VM_MESH_DIR/"
    echo ""
    echo "VM Access:"
    echo "  ssh azureuser@$VM_IP"
    echo ""
    echo "Local Tools:"
    echo "  Istioctl: $ISTIO_DIR/bin/istioctl"
    echo "  Add to PATH: export PATH=\"$ISTIO_DIR/bin:\$PATH\""
    echo "  Sample Apps: ls -la $ISTIO_DIR/samples/"
    echo ""
    echo "Next Steps:"
    echo "  1. Deploy optionally additional sample applications: ./setup-istio.sh deploy-samples"
    echo "  2. Set up VM mesh integration: ./setup-istio.sh setup-vm-mesh"
    echo "  3. Test mesh integration: ./setup-istio.sh deploy-mesh-test"
    echo "     then: ./setup-istio.sh test-mesh"
    echo "  4. Start Port Forwarding: ./setup-istio.sh port-forward"
    echo "  5. Test HelloWorld: curl http://localhost:8080/hello"
    echo "  3. View Kiali dashboard for service mesh topology: http://localhost:20001"
    echo "  7. Stop Port Forwarding: ./setup-istio.sh port-forward stop"
    echo "  8. Clean up resources when done: ./setup-istio.sh cleanup"
    echo "     then optionally: ./setup-istio.sh cleanup local"
    echo ""
}

# Port forwarding function for services and dashboards
setup_port_forwarding() {
    print_header "SETTING UP PORT FORWARDING"
    
    # Check if kubectl is available and cluster is accessible
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster. Please ensure kubectl is configured."
        return 1
    fi
    
    # Check if any port forwarding is already running
    if pgrep -f "kubectl port-forward" > /dev/null; then
        print_warning "Existing kubectl port-forward processes detected."
        echo "Would you like to stop them first? (y/n)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            pkill -f "kubectl port-forward"
            sleep 2
            print_status "Existing port-forward processes stopped"
        fi
    fi
    
    # Array to track background processes
    declare -a PIDS=()
    declare -a SERVICES=()
    
    print_status "Starting port forwarding for Istio add-ons and applications..."
    
    # Function to check if service exists
    check_service() {
        local namespace=$1
        local service=$2
        kubectl get svc "$service" -n "$namespace" &> /dev/null
    }
    
    # Function to check if port is already in use
    check_port() {
        local port=$1
        if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null ; then
            return 1  # Port in use
        else
            return 0  # Port available
        fi
    }
    
    # Function to start port forwarding in background
    start_port_forward() {
        local namespace=$1
        local service=$2
        local local_port=$3
        local remote_port=$4
        local description=$5
        
        if check_service "$namespace" "$service"; then
            if check_port "$local_port"; then
                print_status "Starting port-forward for $description..."
                kubectl port-forward -n "$namespace" svc/"$service" "$local_port:$remote_port" &> /dev/null &
                local pid=$!
                PIDS+=($pid)
                SERVICES+=("$description")
                echo "  ✓ $description: http://localhost:$local_port (PID: $pid)"
                sleep 1  # Give process time to start
                
                # Verify the process is still running
                if ! kill -0 "$pid" 2>/dev/null; then
                    print_warning "Port forwarding for $description failed to start"
                fi
            else
                print_warning "Port $local_port is already in use, skipping $description"
            fi
        else
            print_warning "Service $service not found in namespace $namespace, skipping $description"
        fi
    }
    
    # Function to check if deployment/pod exists
    check_deployment() {
        local namespace=$1
        local selector=$2
        kubectl get pods -n "$namespace" -l "$selector" --no-headers 2>/dev/null | grep -q "Running"
    }
    
    # Function to start port forwarding with retry logic
    start_port_forward_with_retry() {
        local namespace=$1
        local service=$2
        local local_port=$3
        local remote_port=$4
        local description=$5
        local max_retries=3
        local retry_count=0
        local success=false
        
        if check_service "$namespace" "$service"; then
            if check_port "$local_port"; then
                print_status "Starting port-forward for $description (with retry)..."
                
                # For VM services, show endpoint information for debugging
                if [[ "$description" == *"VM"* ]]; then
                    local endpoints=$(kubectl get endpoints "$service" -n "$namespace" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "none")
                    print_status "VM service endpoints: $endpoints"
                    if [ "$endpoints" = "none" ]; then
                        print_warning "No endpoints found for VM service - VM may not be connected to mesh"
                        return 1
                    fi
                fi
                
                while [ $retry_count -lt $max_retries ] && [ "$success" = false ]; do
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -gt 1 ]; then
                        print_status "Retry attempt $retry_count/$max_retries for $description..."
                        sleep 3  # Longer delay for VM services
                    fi
                    
                    kubectl port-forward -n "$namespace" svc/"$service" "$local_port:$remote_port" &> /dev/null &
                    local pid=$!
                    sleep 3  # Give more time for VM connection to establish
                    
                    # Verify the process is still running
                    if kill -0 "$pid" 2>/dev/null; then
                        # Test if port forwarding is actually working
                        if timeout 10 bash -c "echo > /dev/tcp/localhost/$local_port" 2>/dev/null; then
                            success=true
                            PIDS+=($pid)
                            SERVICES+=("$description")
                            if [ $retry_count -eq 1 ]; then
                                echo "  ✓ $description: http://localhost:$local_port (PID: $pid)"
                            else
                                echo "  ✓ $description: http://localhost:$local_port (PID: $pid) - succeeded on attempt $retry_count"
                                print_warning "$description port forwarding required $retry_count attempts - connection may be unstable"
                            fi
                        else
                            # Port forwarding failed, kill the process and retry
                            kill "$pid" 2>/dev/null || true
                            if [ $retry_count -lt $max_retries ]; then
                                if [[ "$description" == *"VM"* ]]; then
                                    print_warning "VM service connection test failed, retrying... (VM services may take longer to respond)"
                                else
                                    print_warning "Port forwarding test failed for $description, retrying..."
                                fi
                            fi
                        fi
                    else
                        if [ $retry_count -lt $max_retries ]; then
                            print_warning "Port forwarding process failed to start for $description, retrying..."
                        fi
                    fi
                done
                
                if [ "$success" = false ]; then
                    print_warning "Port forwarding for $description failed after $max_retries attempts"
                    if [[ "$description" == *"VM"* ]]; then
                        print_status "VM service troubleshooting tips:"
                        print_status "  1. Check if VM is running: az vm show -d -g $RESOURCE_GROUP -n $VM_NAME --query powerState"
                        print_status "  2. Check VM mesh integration: kubectl get workloadentry -n $namespace"
                        print_status "  3. Test VM connectivity: ssh azureuser@\$(VM_IP) 'curl -s localhost:8080'"
                        print_status "  4. Check service endpoints: kubectl get endpoints $service -n $namespace"
                    fi
                fi
            else
                print_warning "Port $local_port is already in use, skipping $description"
            fi
        else
            print_warning "Service $service not found in namespace $namespace, skipping $description"
        fi
    }
    
    # Start port forwarding for Istio add-ons
    echo ""
    echo "Istio Add-ons:"
    start_port_forward "istio-system" "kiali" "20001" "20001" "Kiali Dashboard"
    start_port_forward "istio-system" "grafana" "3000" "3000" "Grafana Dashboard" 
    start_port_forward "istio-system" "tracing" "16686" "80" "Jaeger Tracing"
    start_port_forward "istio-system" "prometheus" "9090" "9090" "Prometheus"
    
    # Start port forwarding for HelloWorld app with retry logic
    echo ""
    echo "Applications:"
    if check_service "helloworld" "helloworld"; then
        start_port_forward_with_retry "helloworld" "helloworld" "8080" "5000" "HelloWorld App"
        # If 8080 failed, try alternative port
        if ! pgrep -f "kubectl port-forward.*helloworld.*8080" > /dev/null; then
            print_status "Port 8080 failed, trying alternative port 8082..."
            start_port_forward_with_retry "helloworld" "helloworld" "8082" "5000" "HelloWorld App (alt port)"
        fi
    else
        print_warning "HelloWorld service not found in helloworld namespace, skipping"
    fi
    
    # Start port forwarding for VM web service (if deployed) with retry logic
    if check_service "vm-workloads" "vm-web-service"; then
        print_status "Found VM web service, attempting port forwarding with retry logic..."
        start_port_forward_with_retry "vm-workloads" "vm-web-service" "8081" "8080" "VM Web Service"
    else
        print_warning "VM Web Service not found in vm-workloads namespace, skipping"
        print_status "Note: VM web service requires VM mesh integration to be set up first"
        print_status "Run: ./setup-istio.sh setup-vm-mesh to configure VM mesh integration"
    fi
    
    echo ""
    
    if [ ${#PIDS[@]} -eq 0 ]; then
        print_warning "No services were successfully port-forwarded."
        print_warning "Make sure your applications are deployed and services are running."
        return 1
    fi
    
    print_status "Port forwarding setup complete!"
    echo ""
    echo "Successfully started port forwarding for ${#PIDS[@]} service(s):"
    for i in "${!SERVICES[@]}"; do
        echo "  - ${SERVICES[$i]}"
    done
    echo ""
    echo "Access URLs:"
    echo "  📊 Kiali Dashboard:     http://localhost:20001"
    echo "  📈 Grafana Dashboard:   http://localhost:3000"
    echo "  🔍 Jaeger Tracing:      http://localhost:16686"
    echo "  📊 Prometheus:          http://localhost:9090"
    echo "  🌍 HelloWorld App:      http://localhost:8080/hello (or http://localhost:8082/hello)"
    echo "  🖥️  VM Web Service:      http://localhost:8081"
    echo ""
    echo "Background Process IDs: ${PIDS[*]}"
    echo ""
    echo "Management Commands:"
    echo "  To stop all port forwarding:"
    echo "    ./setup-istio.sh port-forward stop"
    echo "  Or manually:"
    echo "    kill ${PIDS[*]}"
    echo "    # Or use: pkill -f 'kubectl port-forward'"
    echo ""
    echo "To check running port forwards:"
    echo "  ps aux | grep 'kubectl port-forward'"
    echo "  netstat -tulpn | grep LISTEN | grep -E ':(20001|3000|16686|9090|8080|8081)'"
    echo ""
    
    # Save PIDs to a file for later cleanup
    if [ ${#PIDS[@]} -gt 0 ]; then
        echo "${PIDS[*]}" > "$WORKSPACE_DIR/port-forward-pids.txt"
        print_status "Process IDs saved to $WORKSPACE_DIR/port-forward-pids.txt"
    fi
    
    echo "Press Ctrl+C to stop this script, but port forwarding will continue in the background."
    echo "Press Enter to continue..."
    read -r
}

# Stop port forwarding processes
stop_port_forwarding() {
    print_header "STOPPING PORT FORWARDING"
    
    local pids_file="$WORKSPACE_DIR/port-forward-pids.txt"
    local stopped_count=0
    local already_stopped_count=0
    
    if [ -f "$pids_file" ]; then
        print_status "Reading saved process IDs from $pids_file..."
        local pids=$(cat "$pids_file")
        
        if [ -n "$pids" ]; then
            print_status "Stopping port forwarding processes: $pids"
            
            for pid in $pids; do
                if kill -0 "$pid" 2>/dev/null; then
                    if kill "$pid" 2>/dev/null; then
                        echo "  ✓ Stopped process $pid"
                        stopped_count=$((stopped_count + 1))
                    else
                        echo "  ✗ Failed to stop process $pid"
                    fi
                else
                    echo "  - Process $pid already stopped"
                    already_stopped_count=$((already_stopped_count + 1))
                fi
            done
            
            # Wait a moment for processes to terminate
            sleep 2
            
            # Clean up the PID file
            rm -f "$pids_file"
            print_status "Process IDs file cleaned up"
        else
            print_warning "No process IDs found in file"
        fi
    else
        print_warning "No saved process IDs found."
    fi
    
    # Always attempt to clean up any remaining kubectl port-forward processes
    print_status "Checking for any remaining kubectl port-forward processes..."
    local remaining_pids=$(pgrep -f "kubectl port-forward" || true)
    
    if [ -n "$remaining_pids" ]; then
        print_status "Found additional kubectl port-forward processes: $remaining_pids"
        if pkill -f "kubectl port-forward"; then
            print_status "Successfully stopped additional port-forward processes"
            stopped_count=$((stopped_count + $(echo "$remaining_pids" | wc -w)))
        else
            print_warning "Failed to stop some port-forward processes"
        fi
    else
        print_status "No additional kubectl port-forward processes found"
    fi
    
    echo ""
    print_status "Port forwarding cleanup complete!"
    echo "  Processes stopped: $stopped_count"
    echo "  Already stopped: $already_stopped_count"
    echo ""
    
    # Verify no port forwards are still running
    local still_running=$(pgrep -f "kubectl port-forward" | wc -l || true)
    if [ "$still_running" -eq 0 ]; then
        print_status "✅ All kubectl port-forward processes have been stopped"
    else
        print_warning "⚠️  $still_running kubectl port-forward processes may still be running"
        echo "Run 'ps aux | grep \"kubectl port-forward\"' to check manually"
    fi
}

# Complete setup (updated to include HelloWorld)
complete_setup() {
    print_header "COMPLETE AZURE AKS + ISTIO SETUP WITH HELLOWORLD"
    
    create_local_workspace
    check_prerequisites
    check_existing_resources
    create_resource_group
    create_aks_cluster
    get_aks_credentials
    create_vm
    install_istio
    deploy_helloworld_sample
    setup_tls_certificate # TODO: this may not be required
    configure_vm
    test_helloworld_connectivity
    get_connection_info
    
    print_status "✅ Complete setup with HelloWorld sample finished successfully!"
}

# Setup VM mesh integration
setup_vm_mesh_integration() {
    print_header "SETTING UP VM MESH INTEGRATION"
    
    if [ ! -f "$SCRIPTS_DIR/vm-mesh-integration.sh" ]; then
        print_error "vm-mesh-integration.sh not found in scripts directory"
        return 1
    fi
       
    # Run the VM mesh integration script
    cd "$SCRIPTS_DIR"
    if bash vm-mesh-integration.sh; then
        print_status "✅ VM mesh integration completed successfully"
    else
        print_error "VM mesh integration failed"
        return 1
    fi
    
    cd "$SCRIPT_DIR"
}

# Deploy sample applications
deploy_samples() {
    print_header "DEPLOYING ISTIO SAMPLE APPLICATIONS"
    
    if [ ! -f "$SCRIPTS_DIR/deploy-samples.sh" ]; then
        print_error "deploy-samples.sh not found in scripts directory"
        return 1
    fi
    
    cd "$SCRIPTS_DIR"
    if bash deploy-samples.sh --all; then
        print_status "✅ Sample applications deployed successfully"
    else
        print_error "Sample applications deployment failed"
        return 1
    fi
    
    cd "$SCRIPT_DIR"
}

# Deploy mesh testing applications
deploy_mesh_testing() { 
    cd "$SCRIPTS_DIR"
    if bash deploy-mesh-test.sh; then
        print_status "✅ Mesh testing applications deployed successfully"
    else
        print_error "Mesh testing applications deployment failed"
        return 1
    fi
    
    cd "$SCRIPT_DIR"
}

# Test mesh integration
test_mesh_integration() {   
    cd "$SCRIPTS_DIR"
    if bash test-mesh.sh; then
        print_status "✅ Mesh integration tests passed"
    else
        print_error "Mesh integration tests failed"
        return 1
    fi
    
    cd "$SCRIPT_DIR"
}

# Clean up Azure resources
cleanup_azure() {
    print_header "CLEANING UP AZURE RESOURCES"

    confirm_deletion
    check_azure_login
    cleanup_kubeconfig
    delete_resource_group
}

# Confirm deletion
confirm_deletion() {
    print_warning "This will DELETE the following resources:"
    echo "  - Resource Group: $RESOURCE_GROUP"
    echo "  - AKS Cluster: $CLUSTER_NAME"
    echo "  - VM: $VM_NAME"
    echo "  - All associated networking, storage, and other resources"
    echo ""
    print_warning "This action is IRREVERSIBLE!"
    echo ""
    read -p "Are you sure you want to continue? (type 'DELETE' to confirm): " confirmation
    
    if [ "$confirmation" != "DELETE" ]; then
        print_status "Cleanup cancelled."
        exit 0
    fi
}

# Check Azure login
check_azure_login() {
    print_status "Checking Azure login..."
    
    if ! az account show &> /dev/null; then
        print_error "Not logged into Azure. Please run 'az login' first."
        exit 1
    fi
}

# Clean up local kubeconfig
cleanup_kubeconfig() {
    print_status "Cleaning up local kubeconfig..."
    
    # Remove the cluster context from kubeconfig
    kubectl config delete-context $CLUSTER_NAME 2>/dev/null || true
    kubectl config delete-cluster $CLUSTER_NAME 2>/dev/null || true
    kubectl config unset users.clusterUser_${RESOURCE_GROUP}_${CLUSTER_NAME} 2>/dev/null || true
    
    print_status "Local kubeconfig cleaned up."
}

# Delete resource group (this deletes everything)
delete_resource_group() {
    print_status "Deleting resource group: $RESOURCE_GROUP"
    print_warning "This may take several minutes..."
    
    # Check if resource group exists
    if az group show --name $RESOURCE_GROUP &> /dev/null; then
        az group delete --name $RESOURCE_GROUP --yes --no-wait
        
        print_status "Deletion initiated. Checking progress..."
        
        # Monitor deletion progress
        while az group show --name $RESOURCE_GROUP &> /dev/null; do
            echo -n "."
            sleep 10
        done
        
        echo ""
        print_status "Resource group deleted successfully!"
    else
        print_warning "Resource group $RESOURCE_GROUP not found. It may have already been deleted."
    fi
}

# Clean up local workspace
cleanup_local() {
    print_header "CLEANING UP LOCAL WORKSPACE"
    
    read -p "This will delete the local workspace '$WORKSPACE_DIR' including Istio samples. Are you sure? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        print_status "Local cleanup cancelled"
        return 0
    fi
    
    if [ -d "$WORKSPACE_DIR" ]; then
        print_status "Removing workspace directory and all contents..."
        print_status "  - Istio installation: $ISTIO_DIR"
        print_status "  - Istio samples: $ISTIO_DIR/samples"
        print_status "  - VM mesh setup: $VM_MESH_DIR"
        print_status "  - Certificates: $CERTS_DIR"
        print_status "  - Configurations: $CONFIGS_DIR"
        
        rm -rf "$WORKSPACE_DIR"
        print_status "✅ Local workspace cleaned up"
    else
        print_status "Local workspace doesn't exist"
    fi

    if [ -d "$SCRIPTS_DIR/istio-samples" ]; then
        print_status "Removing Istio samples..."
        rm -rf "$SCRIPTS_DIR/istio-samples"
        print_status "✅ Istio samples removed"
    else
        print_status "Istio samples directory doesn't exist"
    fi
    
    # Remove symlinks
    if [ -L "/tmp/vm-mesh-setup" ]; then
        rm -f "/tmp/vm-mesh-setup"
        print_status "✅ Symlinks removed"
    fi
    
    # Clean up any temporary Istio downloads
    if [ -d "/tmp/istio-*" ]; then
        rm -rf /tmp/istio-*
        print_status "✅ Temporary Istio files cleaned up"
    fi
}

uninstall_istio() {
  print_status "Uninstalling Istio..."

  VM_IP=$(az vm show -d -g $RESOURCE_GROUP -n $VM_NAME --query publicIps -o tsv 2>/dev/null)
  if [ -n "$VM_IP" ]; then
      ssh -o StrictHostKeyChecking=no azureuser@$VM_IP "sudo systemctl stop istio && sudo dpkg -r istio-sidecar && dpkg -s istio-sidecar" 2>/dev/null || print_warning "Could not stop Istio service on VM or service not found"
  fi

  kubectl delete -n istio-system -f ./workspace/istio-installation/samples/multicluster/expose-istiod.yaml 2>/dev/null || true

  istioctl uninstall -y --purge 2>/dev/null || true
  kubectl delete namespace istio-system 2>/dev/null || true

  print_status "✅ Istio uninstalled from the cluster"
}

# Main execution logic
main() {
    parse_arguments "$@"
    
    case $COMMAND in
        help)
            show_usage
            exit 0
            ;;
        status)
            show_status
            ;;
        setup)
            complete_setup
            ;;
        setup-vm-mesh)
            create_local_workspace
            check_prerequisites
            setup_vm_mesh_integration
            ;;
        deploy-samples)
            create_local_workspace
            check_prerequisites
            deploy_samples
            ;;
        deploy-mesh-test)
            create_local_workspace
            check_prerequisites
            deploy_mesh_testing
            ;;
        test-mesh)
            create_local_workspace
            check_prerequisites
            test_mesh_integration
            ;;
        port-forward)
            create_local_workspace
            check_prerequisites
            setup_port_forwarding
            ;;
        stop-port-forward)
            stop_port_forwarding
            ;;
        cleanup)
            cleanup_azure
            ;;
        cleanup-local)
            cleanup_local
            ;;
        uninstall-istio)
            uninstall_istio
            ;;
        *)
            print_error "Unknown command: $COMMAND"
            show_usage
            exit 1
            ;;
    esac
}

# Call main function with all arguments
main "$@"
