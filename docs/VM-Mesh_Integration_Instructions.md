# VM CloudInit Instructions for Istio Mesh Integration

This document provides comprehensive instructions for setting up an Azure VM as part of an Istio service mesh. The process involves two main phases: configuring the cluster-side VM mesh integration and then using CloudInit to automatically set up the VM during creation.

## Part 1: Cluster-Side VM Mesh Integration Setup

Before creating the VM with CloudInit, you must first configure the Kubernetes cluster to support VM mesh integration and generate the required certificates and configuration files.

### Prerequisites

Before starting the cluster-side setup, ensure:

- Azure CLI is installed and logged in
- kubectl is installed and configured to access your AKS cluster
- **Istio is installed on your Kubernetes cluster**
- istioctl CLI tool is available
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

After the VM is created, you'll need to create VM-specific resources that reference the actual VM IP address.

#### Get VM IP Address

```bash
# Get the VM's public IP (replace with your resource group and VM name)
VM_IP=$(az vm show -d -g istio-playground-rg -n istio-vm --query publicIps -o tsv)
echo "VM IP: $VM_IP"
```

#### Create WorkloadEntry for the Specific VM

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

Before proceeding to create the VM, verify the cluster configuration is correct:

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
