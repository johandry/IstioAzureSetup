# VM CloudInit Instructions for Istio Mesh Integration

This document provides comprehensive instructions for setting up Azure VMs as part of an Istio service mesh. The process involves three phases: (1) configuring the cluster-side VM mesh integration, (2) using CloudInit to automatically set up VMs during creation, (3) generate resources and configuring the cluster-side specifically for the new VM and then (4) upload files into the new VM and execute a script from the VM to be integrated into the mesh. It also include instructions to follow when the VM is terminated.

**Multi-VM Support**: This guide supports both single VM deployments and scenarios with multiple VMs being created, terminated, and recreated simultaneously. The architecture separates shared cluster resources from VM-specific resources to enable efficient scaling and lifecycle management.

## Part 1: Cluster-Side VM Mesh Integration Setup

Before creating the VM with CloudInit, you must first configure the Kubernetes cluster to support VM mesh integration and generate the required certificates and configuration files.

### Prerequisites

Before starting the cluster-side setup, ensure:

- Azure CLI is installed and logged in
- `kubectl` is installed and configured to access your AKS cluster
- **Istio is installed on your Kubernetes cluster**
- `istioctl` CLI tool is available
- The VM will be created in the same resource group as your cluster

### Step 1: Verify Cluster Prerequisites

First, verify your cluster has Istio installed and is accessible:

```bash
# Verify kubectl connectivity
kubectl cluster-info

# Verify Istio installation
kubectl get pods -n istio-system

# Verify istioctl is available
istioctl version
```

### Step 2: Configure Cluster Resources for VM Integration

The cluster needs specific resources configured to support VM mesh integration:

#### Create VM Workload Namespace

```bash
# Create namespace for VM workloads
kubectl create namespace vm-workloads

# Enable Istio injection
kubectl label namespace vm-workloads istio-injection=enabled

# Add Azure workload identity support (if using Azure AD)
kubectl label namespace vm-workloads azure.workload.identity/use=true
```

#### Create Service Account for VM

```bash
# Create service account for the VM workload
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vm-workload
  namespace: vm-workloads
  labels:
    azure.workload.identity/use: "true"
  annotations:
    azure.workload.identity/client-id: ""
automountServiceAccountToken: true
EOF
```

#### Create WorkloadGroup for VM Integration

```bash
# Create WorkloadGroup configuration
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: WorkloadGroup
metadata:
  name: vm-web-service
  namespace: vm-workloads
  labels:
    app: vm-web-service
    azure.resource: vm-workload
spec:
  metadata:
    labels:
      app: vm-web-service
      version: v1.0
      azure.zone: westus
  template:
    serviceAccount: vm-workload
    network: vm-network
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
```

#### Configure Service for VM Workload

```bash
# Create Kubernetes Service for the VM workload
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: vm-web-service
  namespace: vm-workloads
  labels:
    app: vm-web-service
spec:
  selector:
    app: vm-web-service
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
```

#### Set Up Authorization Policies

```bash
# Create AuthorizationPolicy for VM workload access
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: vm-workload-policy
  namespace: vm-workloads
spec:
  selector:
    matchLabels:
      app: vm-web-service
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/vm-workloads/sa/vm-workload"]
    - source:
        principals: ["cluster.local/ns/mesh-test/sa/sleep"]
    - source:
        principals: ["cluster.local/ns/helloworld/sa/default"]
  - to:
    - operation:
        methods: ["GET", "POST", "PUT", "DELETE"]
        paths: ["/*"]
EOF

# Create outbound policy for VM to access other services
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: vm-outbound-policy
  namespace: vm-workloads
spec:
  selector:
    matchLabels:
      app: vm-web-service
  action: ALLOW
  rules:
  - to:
    - operation:
        methods: ["GET", "POST"]
EOF
```

### Step 3: Generate VM Configuration Files and Certificates

After configuring the cluster resources, generate the required configuration files and certificates for the VM:

#### Generate VM Files using istioctl

```bash
# Create workspace directory
mkdir -p workspace/vm-mesh-setup/vm-files
cd workspace/vm-mesh-setup

# Create a temporary WorkloadGroup file for generation
cat > vm-files/workloadgroup.yaml <<EOF
apiVersion: networking.istio.io/v1
kind: WorkloadGroup
metadata:
  name: vm-web-service
  namespace: vm-workloads
spec:
  metadata:
    labels:
      app: vm-web-service
      version: v1.0
  template:
    serviceAccount: vm-workload
    network: vm-network
EOF

# Generate VM configuration files
istioctl x workload entry configure \
  -f vm-files/workloadgroup.yaml \
  -o vm-files \
  --clusterID istio-aks-cluster \
  --autoregister

# Clean up temporary file
rm vm-files/workloadgroup.yaml
```

This command generates the following files in `vm-files/`:

- `cluster.env`: Cluster connection configuration
- `hosts`: Host entries for Istio services
- `istio-token`: Service account token for authentication
- `mesh.yaml`: Istio mesh configuration
- `root-cert.pem`: Root certificate for TLS

#### Verify Generated Files

```bash
# Verify all required files are generated
ls -la vm-files/
# Should show: cluster.env, hosts, istio-token, mesh.yaml, root-cert.pem

# Check token validity
kubectl describe secret $(kubectl get serviceaccount vm-workload -n vm-workloads -o jsonpath='{.secrets[0].name}') -n vm-workloads
```

### Step 4: Configure VM-Specific Resources

After VMs are created, you'll need to create VM-specific resources that reference the actual VM IP addresses. This step is performed for each VM individually.

#### Get VM IP Addresses

```bash
# For a single VM
VM_IP=$(az vm show -d -g istio-playground-rg -n istio-vm --query publicIps -o tsv)
echo "VM IP: $VM_IP"

# For multiple VMs - get all VMs with a specific prefix
VM_PREFIX="istio-vm"
RESOURCE_GROUP="istio-playground-rg"

# List all VMs and their IPs
az vm list -g $RESOURCE_GROUP --query "[?starts_with(name, '$VM_PREFIX')].{Name:name, IP:publicIps}" -o table

# Get all VM IPs for processing
VM_IPS=($(az vm list -g $RESOURCE_GROUP --query "[?starts_with(name, '$VM_PREFIX')].publicIps" -o tsv))
VM_NAMES=($(az vm list -g $RESOURCE_GROUP --query "[?starts_with(name, '$VM_PREFIX')].name" -o tsv))
```

#### Create WorkloadEntry for Each VM

For **single VM** deployments:

```bash
# Create WorkloadEntry with the VM's IP address
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  annotations:
    istio.io/autoRegistrationGroup: vm-web-service
  name: vm-web-service-vm
  namespace: vm-workloads
  labels:
    app: vm-web-service
    azure.resource: vm-instance
spec:
  address: "$VM_IP"
  labels:
    app: vm-web-service
    version: v1.0
    azure.zone: westus
  serviceAccount: vm-workload
  network: "vm-network"
  ports:
    http: 8080
    metrics: 15020
    health: 15021
EOF
```

For **multiple VM** deployments:

```bash
# Create WorkloadEntry for each VM with unique naming
for i in "${!VM_NAMES[@]}"; do
    VM_NAME="${VM_NAMES[$i]}"
    VM_IP="${VM_IPS[$i]}"
    
    echo "Creating WorkloadEntry for VM: $VM_NAME with IP: $VM_IP"
    
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  annotations:
    istio.io/autoRegistrationGroup: vm-web-service
  name: vm-web-service-${VM_NAME}
  namespace: vm-workloads
  labels:
    app: vm-web-service
    azure.resource: vm-instance
    vm.name: ${VM_NAME}
spec:
  address: "$VM_IP"
  labels:
    app: vm-web-service
    version: v1.0
    azure.zone: westus
    vm.name: ${VM_NAME}
  serviceAccount: vm-workload
  network: "vm-network"
  ports:
    http: 8080
    metrics: 15020
    health: 15021
EOF
done
```

#### Configure Traffic Management

```bash
# Create VirtualService for traffic routing
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: vm-web-service
  namespace: vm-workloads
spec:
  hosts:
  - vm-web-service.vm-workloads.svc.cluster.local
  gateways:
  - mesh
  http:
  - match:
    - uri:
        prefix: /
    route:
    - destination:
        host: vm-web-service.vm-workloads.svc.cluster.local
        port:
          number: 8080
    timeout: 30s
    retries:
      attempts: 3
      perTryTimeout: 10s
EOF

# Create DestinationRule for mTLS configuration
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: vm-web-service
  namespace: vm-workloads
spec:
  host: vm-web-service.vm-workloads.svc.cluster.local
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
```

### Step 5: Verify Cluster Configuration

Before proceeding to create VMs, verify the cluster configuration is correct:

```bash
# Verify namespace and resources
kubectl get namespace vm-workloads
kubectl get serviceaccount vm-workload -n vm-workloads
kubectl get workloadgroup vm-web-service -n vm-workloads
kubectl get service vm-web-service -n vm-workloads

# Verify authorization policies
kubectl get authorizationpolicy -n vm-workloads

# Verify generated files exist
ls -la workspace/vm-mesh-setup/vm-files/

# For multiple VMs, verify WorkloadEntries after creation
kubectl get workloadentry -n vm-workloads
kubectl get workloadentry -n vm-workloads -o wide  # Shows IP addresses
```

---

## Part 2: VM CloudInit Configuration

After completing the cluster-side setup and generating the required certificates and configuration files, you can create the VM using the following CloudInit configuration.

### Overview

The CloudInit script automates the complete process of:

1. Installing required packages and dependencies
2. Setting up Istio certificates and configuration files
3. Installing Istio sidecar components
4. Setting up monitoring and health checks
5. Starting Istio services in the correct order

### CloudInit Prerequisites

Before using this CloudInit configuration, ensure you have completed Part 1 and:

- The Kubernetes cluster has Istio installed
- VM mesh integration has been configured on the cluster side
- Required certificates and configuration files are available
- The VM has internet access for downloading packages

## CloudInit Configuration

### Base CloudInit Template

```yaml
#cloud-config

# Package updates and basic setup
package_update: true
package_upgrade: true

# Install required packages
packages:
  - curl
  - iptables
  - wget
  - systemd
  - unzip
  - ufw

# Create necessary directories
runcmd:
  # Create working directories
  - mkdir -p /home/azureuser/istio-vm-setup
  
  # Create Istio directories
  - mkdir -p /etc/certs
  - mkdir -p /var/run/secrets/tokens
  - mkdir -p /var/run/secrets/istio/
  - mkdir -p /etc/istio/proxy
  - mkdir -p /etc/istio/config
  - mkdir -p /var/lib/istio/envoy
  - mkdir -p /etc/istio

# Write configuration files
write_files:
  # Health check script
  - path: /home/azureuser/check-service.sh
    permissions: '0755'
    owner: azureuser:azureuser
    content: |
      #!/bin/bash
      # Comprehensive health check script for Istio

      print_status() {
          echo -e "\033[0;32m[INFO]\033[0m $1"
      }

      print_error() {
          echo -e "\033[0;31m[ERROR]\033[0m $1"
      }

      print_warning() {
          echo -e "\033[1;33m[WARNING]\033[0m $1"
      }

      # Check Istio service
      print_status "Checking Istio service..."

      if sudo systemctl is-active --quiet istio; then
          print_status "✓ Istio service is running"
          ISTIO_STATUS=0
      else
          print_error "✗ Istio service is not running"
          ISTIO_STATUS=1
      fi

      # Check Istio admin endpoint
      print_status "Checking Istio admin interface..."

      ISTIO_ADMIN=$(curl -s --connect-timeout 5 http://localhost:15000/stats/prometheus 2>/dev/null | head -n 1)

      if [ -n "$ISTIO_ADMIN" ]; then
          print_status "✓ Istio admin interface is accessible"
          ADMIN_STATUS=0
      else
          print_warning "⚠ Istio admin interface is not accessible"
          ADMIN_STATUS=1
      fi

      # Summary
      echo ""
      echo "=== Health Check Summary ==="
      echo "Istio: $([ $ISTIO_STATUS -eq 0 ] && echo "✓ Running" || echo "✗ Stopped")"
      echo "Istio Admin: $([ $ADMIN_STATUS -eq 0 ] && echo "✓ Available" || echo "⚠ Unavailable")"

      # Exit with appropriate code
      if [ $ISTIO_STATUS -eq 0 ]; then
          exit 0
      else
          exit 1
      fi

  # Service status script
  - path: /home/azureuser/service-status.sh
    permissions: '0755'
    owner: azureuser:azureuser
    content: |
      #!/bin/bash
      # Show detailed status of Istio services

      echo "=== Istio Services Status ==="
      echo ""

      echo "Istio Service:"
      sudo systemctl status istio.service --no-pager -l

      echo ""
      echo "Service Logs (last 10 lines):"
      echo "--- Istio ---"
      sudo journalctl -u istio.service -n 10 --no-pager

  # Istio installation script
  - path: /home/azureuser/install-istio.sh
    permissions: '0755'
    owner: azureuser:azureuser
    content: |
      #!/bin/bash
      # Install Istio sidecar components

      set -e

      print_status() {
          echo -e "\033[0;32m[INFO]\033[0m $1"
      }

      print_error() {
          echo -e "\033[0;31m[ERROR]\033[0m $1"
      }

      ISTIO_VERSION="1.27.0"
      DOWNLOAD_DIR="/tmp/istio-download"

      # Check if pilot-agent is already installed
      if [ -f "/usr/local/bin/pilot-agent" ]; then
          print_status "✓ Istio already installed"
          if /usr/local/bin/pilot-agent version &>/dev/null; then
              print_status "✓ Pilot agent installation verified"
              exit 0
          else
              print_status "Existing pilot-agent installation appears corrupted, reinstalling..."
              sudo rm -f /usr/local/bin/pilot-agent
          fi
      fi

      # Create temporary download directory
      mkdir -p "$DOWNLOAD_DIR"
      cd "$DOWNLOAD_DIR"

      # Clean up any previous downloads
      rm -rf istio-* 2>/dev/null || true

      print_status "Downloading Istio ${ISTIO_VERSION}..."

      # Download with proper error handling
      if ! wget -q --timeout=30 --tries=3 "https://storage.googleapis.com/istio-release/releases/${ISTIO_VERSION}/deb/istio-sidecar.deb"; then
          print_error "Failed to download Istio ${ISTIO_VERSION}"
          exit 1
      fi

      # Verify download
      if [ ! -f "istio-sidecar.deb" ]; then
          print_error "Istio download file not found after download"
          exit 1
      fi

      print_status "Installing Istio..."

      # Installing with proper error handling
      if ! sudo dpkg -i istio-sidecar.deb; then
          print_error "Failed to install Istio package"
          exit 1
      fi

      # Verify installation
      if /usr/local/bin/pilot-agent version &>/dev/null; then
          print_status "✓ Istio installed successfully"
      else
          print_error "Pilot agent installation verification failed"
          exit 1
      fi

      # Cleanup download directory
      cd /home/azureuser
      rm -rf "$DOWNLOAD_DIR"

      print_status "✓ Istio installation completed"

  # VM mesh setup completion script
  - path: /home/azureuser/complete-mesh-setup.sh
    permissions: '0755'
    owner: azureuser:azureuser
    content: |
      #!/bin/bash
      # Complete the mesh setup after certificates are received

      set -e

      print_status() {
          echo -e "\033[0;32m[INFO]\033[0m $1"
      }

      print_error() {
          echo -e "\033[0;31m[ERROR]\033[0m $1"
      }

      print_warning() {
          echo -e "\033[1;33m[WARNING]\033[0m $1"
      }

      # Check if required files exist
      if [ ! -d "/tmp/vm-files" ]; then
          print_error "VM files directory not found. Please ensure certificates and configuration files are transferred."
          exit 1
      fi

      # Validate required files
      required_files=("istio-token" "root-cert.pem" "cluster.env" "mesh.yaml" "hosts")
      for file in "${required_files[@]}"; do
          if [ ! -f "/tmp/vm-files/$file" ]; then
              print_error "Required file not found: $file"
              exit 1
          fi
      done

      print_status "Installing Istio certificates and configuration..."

      # Copy certificates
      sudo cp /tmp/vm-files/root-cert.pem /etc/certs/
      sudo chmod 644 /etc/certs/root-cert.pem
      sudo cp /etc/certs/root-cert.pem /var/run/secrets/istio/

      # Copy Istio token
      sudo cp /tmp/vm-files/istio-token /var/run/secrets/tokens/istio-token
      sudo chmod 644 /var/run/secrets/tokens/istio-token

      # Update hosts file
      sudo sh -c "cat /tmp/vm-files/hosts >> /etc/hosts"
      sudo sh -c "echo '127.0.0.1 istio-vm' >> /etc/hosts"

      # Copy mesh configuration
      sudo cp /tmp/vm-files/mesh.yaml /etc/istio/config/mesh
      sudo chmod 644 /etc/istio/config/mesh

      # Copy cluster environment
      sudo cp /tmp/vm-files/cluster.env /var/lib/istio/envoy/
      sudo chmod 644 /var/lib/istio/envoy/cluster.env

      # Set proper ownership
      sudo chown -R istio-proxy:istio-proxy /etc/certs /var/run/secrets /var/lib/istio /etc/istio/proxy /etc/istio/config

      print_status "Starting Istio services..."

      # Start Istio
      sudo systemctl start istio.service
      sleep 15

      print_status "✓ Mesh setup completed successfully!"
      print_status "Run ./check-service.sh to verify Istio is healthy"

# Configure firewall
runcmd:
  # Configure UFW firewall
  - ufw --force enable
  - ufw allow 22/tcp comment 'SSH management'
  - ufw allow 15000:15090/tcp comment 'Istio sidecar ports'
  - ufw allow out 15012/tcp comment 'Istio discovery'
  
  # Install Istio
  - sudo -u azureuser /home/azureuser/install-istio.sh
  
  # Enable services
  - systemctl daemon-reload
  
  # Set ownership for azureuser files
  - chown -R azureuser:azureuser /home/azureuser/

# Final message
final_message: |
  VM CloudInit setup completed!
  
  To complete Istio mesh integration:
  1. Transfer certificates and configuration files to /tmp/vm-files/
  2. Run: sudo -u azureuser /home/azureuser/complete-mesh-setup.sh
  3. Verify: sudo -u azureuser /home/azureuser/check-service.sh
  
  Istio admin interface: http://VM_IP:15000/stats/prometheus
```

## Manual Steps After VM Creation

After the VM is created with CloudInit, you'll need to complete the mesh integration by transferring the configuration files generated in Part 1:

### 1. Transfer Configuration Files to VM

Transfer the configuration files generated in Part 1 to the VM:

```bash
# Get VM IP (if not already known)
VM_IP=$(az vm show -d -g istio-playground-rg -n istio-vm --query publicIps -o tsv)

# Create directory on VM
ssh azureuser@$VM_IP 'mkdir -p /tmp/vm-files'

# Transfer all configuration files generated in Part 1
scp -r workspace/vm-mesh-setup/vm-files/* azureuser@$VM_IP:/tmp/vm-files/
```

### 2. Complete Mesh Setup

SSH to the VM and complete the setup:

```bash
# SSH to VM
ssh azureuser@$VM_IP

# Complete the mesh integration
./complete-mesh-setup.sh

# Verify all services are healthy
./check-service.sh
```

## Monitoring and Maintenance

### Health Checks

```bash
# Run comprehensive health check
./check-service.sh

# Check detailed service status
./service-status.sh

# Check individual services
sudo systemctl status istio
```

### Logs

```bash
# Istio logs  
sudo journalctl -u istio -f
```

### Service Management

```bash
# Restart services
sudo systemctl restart istio

# Check service status
sudo systemctl status istio

# Disable/enable services
sudo systemctl disable istio
sudo systemctl enable istio
```

## Troubleshooting

### Common Issues

1. **Istio connection issues**: Verify certificates and token are properly configured
2. **Network connectivity**: Check if VM can reach Kubernetes API server
3. **Service discovery**: Ensure VM is registered in Istio service registry

### Debug Commands

```bash
# Check firewall status
sudo ufw status verbose

# Verify Istio admin interface
curl http://localhost:15000/stats/prometheus | head

# Check certificate permissions
ls -la /etc/certs/ /var/run/secrets/tokens/
```

## VM Termination and Recreation (Single and Multiple VMs)

When VMs need to be terminated but will eventually be recreated (e.g., for maintenance, scaling, or updates), you need to clean up VM-specific resources while preserving the shared cluster configuration. This section covers both single VM and multiple VM scenarios.

### Resources to Keep (Shared Infrastructure)

These resources should **NOT** be deleted as they are shared across all VMs in the mesh:

- **Namespace**: `vm-workloads` namespace
- **Service Account**: `vm-workload` service account  
- **WorkloadGroup**: `vm-web-service` workload group
- **Service**: `vm-web-service` Kubernetes service
- **Authorization Policies**: Security policies for VM workloads
- **VirtualService**: Traffic routing configuration
- **DestinationRule**: mTLS and traffic policy configuration
- **Generated certificates and configuration files**: Can be reused across all VMs

### Resources to Clean Up (VM-Specific)

These resources are specific to individual VMs and should be cleaned up when VMs are terminated:

#### Single VM Cleanup

```bash
# Find and delete the WorkloadEntry for the terminated VM
kubectl get workloadentry -n vm-workloads

# Delete the specific WorkloadEntry (replace with actual name)
kubectl delete workloadentry vm-web-service-vm -n vm-workloads

# Or delete by label if auto-registered
kubectl delete workloadentry -n vm-workloads -l app=vm-web-service
```

#### Multiple VM Cleanup

For cleaning up specific VMs by name:

```bash
# Clean up WorkloadEntries for specific VMs
VM_NAMES_TO_DELETE=("istio-vm-1" "istio-vm-3" "istio-vm-5")

for VM_NAME in "${VM_NAMES_TO_DELETE[@]}"; do
    echo "Cleaning up WorkloadEntry for VM: $VM_NAME"
    kubectl delete workloadentry "vm-web-service-${VM_NAME}" -n vm-workloads --ignore-not-found=true
done
```

For cleaning up VMs by IP address:

```bash
# Clean up WorkloadEntries for terminated VMs by IP
TERMINATED_IPS=("10.0.1.4" "10.0.1.7" "10.0.1.10")

for VM_IP in "${TERMINATED_IPS[@]}"; do
    echo "Cleaning up WorkloadEntry for IP: $VM_IP"
    WORKLOAD_ENTRY=$(kubectl get workloadentry -n vm-workloads -o json | \
      jq -r ".items[] | select(.spec.address == \"$VM_IP\") | .metadata.name")
    
    if [ -n "$WORKLOAD_ENTRY" ] && [ "$WORKLOAD_ENTRY" != "null" ]; then
        kubectl delete workloadentry "$WORKLOAD_ENTRY" -n vm-workloads
        echo "✓ Deleted WorkloadEntry: $WORKLOAD_ENTRY"
    else
        echo "⚠ No WorkloadEntry found for IP: $VM_IP"
    fi
done
```

For bulk cleanup (all VMs):

```bash
# Clean up all WorkloadEntries (use with caution)
kubectl delete workloadentry -n vm-workloads -l app=vm-web-service

# Or more selective cleanup by excluding specific VMs
kubectl get workloadentry -n vm-workloads -o name | \
  grep -v "vm-web-service-keep-this-vm" | \
  xargs -r kubectl delete
```

#### 2. Clean Up Auto-Registered Resources

If using auto-registration, Istio may create additional resources:

```bash
# List all workload entries to find auto-generated ones
kubectl get workloadentry -n vm-workloads

# Delete auto-generated entries (they typically include IP addresses in the name)
kubectl get workloadentry -n vm-workloads -o name | grep -E "vm-web-service-[0-9]" | xargs -r kubectl delete
```

#### 3. Verify Cleanup

Ensure VM-specific resources are removed:

```bash
# Verify no WorkloadEntries exist for the terminated VM
kubectl get workloadentry -n vm-workloads

# Check that shared resources remain intact
kubectl get service vm-web-service -n vm-workloads
kubectl get workloadgroup vm-web-service -n vm-workloads
kubectl get authorizationpolicy -n vm-workloads
```

### Creating New VMs (Single and Multiple)

When creating new VMs to replace terminated ones or scaling up:

#### 1. Use the Same CloudInit Configuration

The CloudInit configuration from Part 2 can be reused for all VMs since the cluster-side configuration remains intact.

#### 2. Transfer Configuration Files to Multiple VMs

The certificates and configuration files generated in Part 1 can be reused for all VMs:

**For a single new VM:**

```bash
# Get the new VM's IP address
NEW_VM_IP=$(az vm show -d -g istio-playground-rg -n istio-vm --query publicIps -o tsv)

# Transfer the existing configuration files
scp -r workspace/vm-mesh-setup/vm-files/* azureuser@$NEW_VM_IP:/tmp/vm-files/
```

**For multiple new VMs:**

```bash
# Get all new VM IPs
VM_PREFIX="istio-vm"
RESOURCE_GROUP="istio-playground-rg"

NEW_VM_IPS=($(az vm list -g $RESOURCE_GROUP --query "[?starts_with(name, '$VM_PREFIX')].publicIps" -o tsv))
NEW_VM_NAMES=($(az vm list -g $RESOURCE_GROUP --query "[?starts_with(name, '$VM_PREFIX')].name" -o tsv))

# Transfer configuration files to all new VMs
for i in "${!NEW_VM_IPS[@]}"; do
    VM_NAME="${NEW_VM_NAMES[$i]}"
    VM_IP="${NEW_VM_IPS[$i]}"
    
    echo "Transferring files to VM: $VM_NAME ($VM_IP)"
    
    # Create directory and transfer files
    ssh -o StrictHostKeyChecking=no azureuser@$VM_IP 'mkdir -p /tmp/vm-files' && \
    scp -r -o StrictHostKeyChecking=no workspace/vm-mesh-setup/vm-files/* azureuser@$VM_IP:/tmp/vm-files/
    
    echo "✓ Files transferred to $VM_NAME"
done
```

#### 3. Create VM-Specific WorkloadEntries

**For a single new VM:**

```bash
# Get the new VM's details
NEW_VM_IP=$(az vm show -d -g istio-playground-rg -n istio-vm --query publicIps -o tsv)
NEW_VM_NAME="istio-vm"

# Create WorkloadEntry for the new VM
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  annotations:
    istio.io/autoRegistrationGroup: vm-web-service
  name: vm-web-service-${NEW_VM_NAME}
  namespace: vm-workloads
  labels:
    app: vm-web-service
    azure.resource: vm-instance
    vm.name: ${NEW_VM_NAME}
spec:
  address: "$NEW_VM_IP"
  labels:
    app: vm-web-service
    version: v1.0
    azure.zone: westus
    vm.name: ${NEW_VM_NAME}
  serviceAccount: vm-workload
  network: "vm-network"
  ports:
    http: 8080
    metrics: 15020
    health: 15021
EOF
```

**For multiple new VMs:**

```bash
# Create WorkloadEntries for all new VMs
for i in "${!NEW_VM_NAMES[@]}"; do
    VM_NAME="${NEW_VM_NAMES[$i]}"
    VM_IP="${NEW_VM_IPS[$i]}"
    
    echo "Creating WorkloadEntry for VM: $VM_NAME with IP: $VM_IP"
    
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  annotations:
    istio.io/autoRegistrationGroup: vm-web-service
  name: vm-web-service-${VM_NAME}
  namespace: vm-workloads
  labels:
    app: vm-web-service
    azure.resource: vm-instance
    vm.name: ${VM_NAME}
spec:
  address: "$VM_IP"
  labels:
    app: vm-web-service
    version: v1.0
    azure.zone: westus
    vm.name: ${VM_NAME}
  serviceAccount: vm-workload
  network: "vm-network"
  ports:
    http: 8080
    metrics: 15020
    health: 15021
EOF
done
```

#### 4. Verify VM Integration

**For single VM:**

```bash
# Check WorkloadEntry is created
kubectl get workloadentry -n vm-workloads

# Test connectivity from cluster to VM
kubectl exec -n mesh-test deployment/sleep -- curl -v http://vm-web-service.vm-workloads:8080/

# Verify VM can reach cluster services
NEW_VM_IP=$(az vm show -d -g istio-playground-rg -n istio-vm --query publicIps -o tsv)
ssh azureuser@$NEW_VM_IP './check-service.sh'
```

**For multiple VMs:**

```bash
# Check all WorkloadEntries
kubectl get workloadentry -n vm-workloads -o wide

# Verify each VM individually
for i in "${!NEW_VM_IPS[@]}"; do
    VM_NAME="${NEW_VM_NAMES[$i]}"
    VM_IP="${NEW_VM_IPS[$i]}"
    
    echo "Verifying VM: $VM_NAME ($VM_IP)"
    
    # Test mesh connectivity
    ssh -o StrictHostKeyChecking=no azureuser@$VM_IP './check-service.sh'
    
    if [ $? -eq 0 ]; then
        echo "✓ $VM_NAME is healthy and connected to mesh"
    else
        echo "✗ $VM_NAME has connectivity issues"
    fi
done

# Test load balancing across multiple VMs
echo "Testing load balancing across all VMs..."
for i in {1..10}; do
    kubectl exec -n mesh-test deployment/sleep -- curl -s http://vm-web-service.vm-workloads:8080/ | head -1
done
```

### Automation Scripts for VM Lifecycle Management

#### Single VM Cleanup Script

```bash
#!/bin/bash
# cleanup-single-vm.sh

VM_IP="$1"
NAMESPACE="vm-workloads"

if [ -z "$VM_IP" ]; then
    echo "Usage: $0 <VM_IP_ADDRESS>"
    exit 1
fi

echo "Cleaning up resources for VM: $VM_IP"

# Delete WorkloadEntry by IP address
kubectl get workloadentry -n $NAMESPACE -o json | \
  jq -r ".items[] | select(.spec.address == \"$VM_IP\") | .metadata.name" | \
  xargs -I {} kubectl delete workloadentry {} -n $NAMESPACE

echo "✓ VM-specific resources cleaned up for IP: $VM_IP"
```

#### Multiple VMs Cleanup Script

```bash
#!/bin/bash
# cleanup-multiple-vms.sh

NAMESPACE="vm-workloads"

# Accept either VM names or IP addresses as arguments
cleanup_by_names() {
    local vm_names=("$@")
    
    for VM_NAME in "${vm_names[@]}"; do
        echo "Cleaning up WorkloadEntry for VM: $VM_NAME"
        kubectl delete workloadentry "vm-web-service-${VM_NAME}" -n $NAMESPACE --ignore-not-found=true
        echo "✓ Cleaned up VM: $VM_NAME"
    done
}

cleanup_by_ips() {
    local vm_ips=("$@")
    
    for VM_IP in "${vm_ips[@]}"; do
        echo "Cleaning up WorkloadEntry for IP: $VM_IP"
        WORKLOAD_ENTRY=$(kubectl get workloadentry -n $NAMESPACE -o json | \
          jq -r ".items[] | select(.spec.address == \"$VM_IP\") | .metadata.name")
        
        if [ -n "$WORKLOAD_ENTRY" ] && [ "$WORKLOAD_ENTRY" != "null" ]; then
            kubectl delete workloadentry "$WORKLOAD_ENTRY" -n $NAMESPACE
            echo "✓ Deleted WorkloadEntry: $WORKLOAD_ENTRY"
        else
            echo "⚠ No WorkloadEntry found for IP: $VM_IP"
        fi
    done
}

# Usage examples:
# ./cleanup-multiple-vms.sh names istio-vm-1 istio-vm-2 istio-vm-3
# ./cleanup-multiple-vms.sh ips 10.0.1.4 10.0.1.5 10.0.1.6

if [ "$1" == "names" ]; then
    shift
    cleanup_by_names "$@"
elif [ "$1" == "ips" ]; then
    shift
    cleanup_by_ips "$@"
else
    echo "Usage: $0 [names|ips] <list_of_vms>"
    echo "Examples:"
    echo "  $0 names vm1 vm2 vm3"
    echo "  $0 ips 10.0.1.4 10.0.1.5"
    exit 1
fi

echo "✓ Multiple VM cleanup completed"
```

#### Bulk VM Creation Script

```bash
#!/bin/bash
# create-multiple-vm-workloadentries.sh

NAMESPACE="vm-workloads"
RESOURCE_GROUP="istio-playground-rg"
VM_PREFIX="istio-vm"

# Get all VMs with the specified prefix
VM_NAMES=($(az vm list -g $RESOURCE_GROUP --query "[?starts_with(name, '$VM_PREFIX')].name" -o tsv))
VM_IPS=($(az vm list -g $RESOURCE_GROUP --query "[?starts_with(name, '$VM_PREFIX')].publicIps" -o tsv))

if [ ${#VM_NAMES[@]} -eq 0 ]; then
    echo "No VMs found with prefix: $VM_PREFIX"
    exit 1
fi

echo "Found ${#VM_NAMES[@]} VMs to configure:"
for i in "${!VM_NAMES[@]}"; do
    echo "  ${VM_NAMES[$i]} - ${VM_IPS[$i]}"
done

# Create WorkloadEntry for each VM
for i in "${!VM_NAMES[@]}"; do
    VM_NAME="${VM_NAMES[$i]}"
    VM_IP="${VM_IPS[$i]}"
    
    echo "Creating WorkloadEntry for VM: $VM_NAME with IP: $VM_IP"
    
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  annotations:
    istio.io/autoRegistrationGroup: vm-web-service
  name: vm-web-service-${VM_NAME}
  namespace: $NAMESPACE
  labels:
    app: vm-web-service
    azure.resource: vm-instance
    vm.name: ${VM_NAME}
spec:
  address: "$VM_IP"
  labels:
    app: vm-web-service
    version: v1.0
    azure.zone: westus
    vm.name: ${VM_NAME}
  serviceAccount: vm-workload
  network: "vm-network"
  ports:
    http: 8080
    metrics: 15020
    health: 15021
EOF

    echo "✓ Created WorkloadEntry for $VM_NAME"
done

echo "✓ All WorkloadEntries created successfully"
```

#### VM Health Check Script

```bash
#!/bin/bash
# check-all-vms-health.sh

NAMESPACE="vm-workloads"

# Get all WorkloadEntries and their IP addresses
VM_DATA=$(kubectl get workloadentry -n $NAMESPACE -o json | \
  jq -r '.items[] | "\(.spec.address) \(.metadata.labels["vm.name"] // "unknown")"')

if [ -z "$VM_DATA" ]; then
    echo "No VMs found in the mesh"
    exit 1
fi

echo "Checking health of all VMs in the mesh..."
echo "============================================="

while IFS=' ' read -r VM_IP VM_NAME; do
    echo "Checking VM: $VM_NAME ($VM_IP)"
    
    # Test SSH connectivity and service health
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no azureuser@$VM_IP './check-service.sh' >/dev/null 2>&1; then
        echo "  ✓ $VM_NAME is healthy"
    else
        echo "  ✗ $VM_NAME is unhealthy or unreachable"
    fi
done <<< "$VM_DATA"

echo ""
echo "Mesh connectivity test from cluster:"
echo "===================================="

# Test connectivity from cluster to service (load balanced across all VMs)
if kubectl exec -n mesh-test deployment/sleep -- curl -s --max-time 5 http://vm-web-service.vm-workloads:8080/ >/dev/null 2>&1; then
    echo "✓ Service vm-web-service is accessible from cluster"
else
    echo "✗ Service vm-web-service is not accessible from cluster"
fi
```

### Best Practices for VM Lifecycle Management

#### Single VM Scenarios

1. **Document VM IP addresses**: Keep track of which WorkloadEntries correspond to which VM instances
2. **Use consistent naming**: Name WorkloadEntries consistently to make cleanup easier
3. **Test connectivity**: Always verify mesh connectivity after recreating VMs

#### Multiple VM Scenarios

1. **Implement consistent naming conventions**: Use predictable patterns like `vm-web-service-{vm-name}` for WorkloadEntries
2. **Use labels for VM identification**: Add `vm.name` labels to WorkloadEntries for easier management
3. **Batch operations**: Use scripts for bulk creation, deletion, and health checks
4. **Load balancing verification**: Test that traffic is properly distributed across all healthy VMs
5. **Rolling updates**: When updating multiple VMs, do it in batches to maintain service availability

#### General Best Practices

1. **Automate cleanup**: Include cleanup steps in your VM termination automation
2. **Monitor orphaned resources**: Regularly check for WorkloadEntries that point to terminated VMs
3. **Health monitoring**: Implement automated health checks across all VMs
4. **Configuration management**: Keep VM configuration files in version control
5. **Disaster recovery**: Document procedures for recreating entire VM fleets
6. **Resource tagging**: Use consistent Azure tags and Kubernetes labels for resource management

#### Scaling Considerations

- **Horizontal scaling**: Add/remove VMs by creating/deleting WorkloadEntries
- **Blue-green deployments**: Create new VMs with different version labels, then switch traffic
- **Canary deployments**: Use subset routing to gradually shift traffic to new VM versions
- **Resource limits**: Monitor Kubernetes API server load when managing large numbers of WorkloadEntries

## Managing Multiple VMs Simultaneously

This section addresses scenarios where multiple VMs are being created and terminated at the same time, such as during scaling operations, rolling updates, or auto-scaling events.

### Scenario: Mixed Operations (Create + Terminate)

When you need to simultaneously terminate some VMs and create others:

#### Step 1: Plan the Operation

```bash
# Define VMs to be terminated
VMS_TO_TERMINATE=("istio-vm-old-1" "istio-vm-old-2" "istio-vm-old-3")
TERMINATE_IPS=("10.0.1.4" "10.0.1.5" "10.0.1.6")

# Define new VMs to be created (assuming they're already deployed)
NEW_VMS=("istio-vm-new-1" "istio-vm-new-2" "istio-vm-new-3")
NEW_IPS=("10.0.1.10" "10.0.1.11" "10.0.1.12")

echo "Planning to terminate ${#VMS_TO_TERMINATE[@]} VMs and create ${#NEW_VMS[@]} VMs"
```

#### Step 2: Create New VMs First (Blue-Green Strategy)

```bash
# Create WorkloadEntries for new VMs first
for i in "${!NEW_VMS[@]}"; do
    VM_NAME="${NEW_VMS[$i]}"
    VM_IP="${NEW_IPS[$i]}"
    
    echo "Creating WorkloadEntry for new VM: $VM_NAME ($VM_IP)"
    
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  annotations:
    istio.io/autoRegistrationGroup: vm-web-service
  name: vm-web-service-${VM_NAME}
  namespace: vm-workloads
  labels:
    app: vm-web-service
    azure.resource: vm-instance
    vm.name: ${VM_NAME}
    deployment.version: new
spec:
  address: "$VM_IP"
  labels:
    app: vm-web-service
    version: v1.0
    azure.zone: westus
    vm.name: ${VM_NAME}
    deployment.version: new
  serviceAccount: vm-workload
  network: "vm-network"
  ports:
    http: 8080
    metrics: 15020
    health: 15021
EOF
done
```

#### Step 3: Verify New VMs Health

```bash
# Wait for new VMs to be healthy before proceeding
for i in "${!NEW_VMS[@]}"; do
    VM_NAME="${NEW_VMS[$i]}"
    VM_IP="${NEW_IPS[$i]}"
    
    echo "Checking health of new VM: $VM_NAME"
    
    # Wait up to 60 seconds for VM to be healthy
    for attempt in {1..12}; do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no azureuser@$VM_IP './check-service.sh' >/dev/null 2>&1; then
            echo "✓ $VM_NAME is healthy"
            break
        else
            if [ $attempt -eq 12 ]; then
                echo "✗ $VM_NAME failed to become healthy after 60 seconds"
                exit 1
            fi
            echo "⏳ Waiting for $VM_NAME to become healthy (attempt $attempt/12)"
            sleep 5
        fi
    done
done
```

#### Step 4: Remove Old VMs

```bash
# Only after new VMs are confirmed healthy, remove old ones
for i in "${!VMS_TO_TERMINATE[@]}"; do
    VM_NAME="${VMS_TO_TERMINATE[$i]}"
    
    echo "Removing WorkloadEntry for old VM: $VM_NAME"
    kubectl delete workloadentry "vm-web-service-${VM_NAME}" -n vm-workloads --ignore-not-found=true
    
    echo "✓ Cleaned up old VM: $VM_NAME"
done
```

#### Step 5: Verify Service Continuity

```bash
# Test that the service is still available and load balancing works
echo "Testing service continuity..."

for i in {1..10}; do
    if kubectl exec -n mesh-test deployment/sleep -- curl -s --max-time 5 http://vm-web-service.vm-workloads:8080/ >/dev/null; then
        echo "✓ Request $i successful"
    else
        echo "✗ Request $i failed"
    fi
done

# Check final state
echo "Final WorkloadEntry state:"
kubectl get workloadentry -n vm-workloads -o wide
```

### Scenario: Auto-Scaling Operations

For auto-scaling scenarios where VMs are dynamically added and removed:

#### Auto-Scale Up Script

```bash
#!/bin/bash
# auto-scale-up.sh

NAMESPACE="vm-workloads"
SCALE_COUNT="$1"

if [ -z "$SCALE_COUNT" ]; then
    echo "Usage: $0 <number_of_vms_to_add>"
    exit 1
fi

echo "Scaling up by $SCALE_COUNT VMs..."

# Assume Azure VMSS or similar has created new VMs
# Get newly created VMs (this would be integrated with your VM creation process)
RESOURCE_GROUP="istio-playground-rg"
VM_PREFIX="istio-vm-scale"

# Get VMs that don't have WorkloadEntries yet
ALL_VMS=($(az vm list -g $RESOURCE_GROUP --query "[?starts_with(name, '$VM_PREFIX')].name" -o tsv))
EXISTING_ENTRIES=($(kubectl get workloadentry -n $NAMESPACE -o json | jq -r '.items[].metadata.labels["vm.name"] // empty'))

# Find VMs without WorkloadEntries
NEW_VMS=()
for vm in "${ALL_VMS[@]}"; do
    if [[ ! " ${EXISTING_ENTRIES[@]} " =~ " ${vm} " ]]; then
        NEW_VMS+=("$vm")
    fi
done

# Create WorkloadEntries for new VMs
for VM_NAME in "${NEW_VMS[@]:0:$SCALE_COUNT}"; do
    VM_IP=$(az vm show -d -g $RESOURCE_GROUP -n $VM_NAME --query publicIps -o tsv)
    
    echo "Adding VM to mesh: $VM_NAME ($VM_IP)"
    
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  annotations:
    istio.io/autoRegistrationGroup: vm-web-service
  name: vm-web-service-${VM_NAME}
  namespace: $NAMESPACE
  labels:
    app: vm-web-service
    azure.resource: vm-instance
    vm.name: ${VM_NAME}
    auto-scaled: "true"
spec:
  address: "$VM_IP"
  labels:
    app: vm-web-service
    version: v1.0
    azure.zone: westus
    vm.name: ${VM_NAME}
  serviceAccount: vm-workload
  network: "vm-network"
  ports:
    http: 8080
    metrics: 15020
    health: 15021
EOF

    echo "✓ Added $VM_NAME to service mesh"
done

echo "✅ Scale-up completed. Added ${#NEW_VMS[@]} VMs to the mesh."
```

#### Auto-Scale Down Script

```bash
#!/bin/bash
# auto-scale-down.sh

NAMESPACE="vm-workloads"
SCALE_DOWN_COUNT="$1"

if [ -z "$SCALE_DOWN_COUNT" ]; then
    echo "Usage: $0 <number_of_vms_to_remove>"
    exit 1
fi

echo "Scaling down by $SCALE_DOWN_COUNT VMs..."

# Get auto-scaled VMs (prioritize removing auto-scaled ones first)
AUTO_SCALED_VMS=($(kubectl get workloadentry -n $NAMESPACE -l auto-scaled=true -o json | \
  jq -r '.items[] | .metadata.labels["vm.name"]'))

if [ ${#AUTO_SCALED_VMS[@]} -lt $SCALE_DOWN_COUNT ]; then
    echo "Warning: Only ${#AUTO_SCALED_VMS[@]} auto-scaled VMs available, but requested to remove $SCALE_DOWN_COUNT"
fi

# Remove the specified number of VMs (or all available auto-scaled VMs)
VMS_TO_REMOVE=(${AUTO_SCALED_VMS[@]:0:$SCALE_DOWN_COUNT})

for VM_NAME in "${VMS_TO_REMOVE[@]}"; do
    echo "Removing VM from mesh: $VM_NAME"
    kubectl delete workloadentry "vm-web-service-${VM_NAME}" -n $NAMESPACE
    echo "✓ Removed $VM_NAME from service mesh"
done

echo "✅ Scale-down completed. Removed ${#VMS_TO_REMOVE[@]} VMs from the mesh."
```

### Monitoring and Observability

For multiple VM scenarios, enhanced monitoring is crucial:

```bash
# Monitor all VMs in real-time
kubectl get workloadentry -n vm-workloads -w

# Get detailed status of all VMs
kubectl get workloadentry -n vm-workloads -o custom-columns=\
NAME:.metadata.name,\
VM_NAME:.metadata.labels.vm\.name,\
IP:.spec.address,\
VERSION:.spec.labels.version,\
AUTO_SCALED:.metadata.labels.auto-scaled

# Check service endpoints (should include all healthy VMs)
kubectl get endpoints vm-web-service -n vm-workloads -o yaml
```

## Security Considerations

- Istio sidecar uses ports 15000-15090 for administration and metrics
- UFW firewall is configured to allow only necessary ports for Istio
- All Istio services run under the istio-proxy user account
- SSH access is maintained on port 22 for administration

## Customization

You can customize the CloudInit script by:

1. **Custom monitoring**: Add additional health check scripts for your existing web services
2. **Additional packages**: Add more packages to the `packages` section
3. **Istio configuration**: Modify Istio settings in the configuration files
4. **Firewall rules**: Add custom firewall rules for your existing services

## Integration with Azure ARM Templates

This CloudInit configuration can be embedded in Azure ARM templates or Bicep files:

```json
{
  "type": "Microsoft.Compute/virtualMachines",
  "properties": {
    "osProfile": {
      "customData": "[base64(variables('cloudInitContent'))]"
    }
  }
}
```

Where `cloudInitContent` contains the CloudInit YAML configuration above.
