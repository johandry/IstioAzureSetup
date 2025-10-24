# Salt Configuration Usage Examples

This document provides practical examples for using the Salt configuration to set up Istio VM mesh integration.

## Quick Start Example

### 1. Build VM Image with Salt

```bash
# Build a VM image with Salt configuration
./build-image.sh istio-playground-rg my-base-vm istio-vm-image westus2

# This will:
# - Create base VM if needed
# - Install Salt
# - Copy Salt configuration files  
# - Execute image-build.sls
# - Create VM image snapshot
```

### 2. Deploy VMs from Image

```bash
# Deploy 3 VMs from the prepared image
./deploy-vms.sh istio-playground-rg istio-vm-image istio-vm 3

# This will:
# - Create 3 VMs named istio-vm-1, istio-vm-2, istio-vm-3
# - Wait for VMs to be SSH accessible
# - Transfer certificates (if available)
# - Verify health
```

### 3. Check VM Health

```bash
# Check health of all deployed VMs
./check-all-vms.sh istio-playground-rg istio-vm

# This will:
# - Find all VMs with istio-vm prefix
# - Check SSH connectivity
# - Run health checks
# - Verify Istio and Salt status
```

## Manual Salt Operations

### Execute Salt States

```bash
# Run image build state (during image creation)
sudo salt-call --local state.apply image-build

# Run boot-time state (at VM startup or manually)
sudo salt-call --local state.apply boot-time

# Test state without applying changes
sudo salt-call --local state.apply boot-time test=True

# Run with debug output
sudo salt-call --local state.apply boot-time -l debug
```

### Check Salt Status

```bash
# View Salt grains (system information)
sudo salt-call --local grains.items

# Show current highstate (what Salt would do)
sudo salt-call --local state.show_highstate

# Check specific state file
sudo salt-call --local state.show_sls boot-time
```

## Certificate Management Examples

### Transfer Certificates to Single VM

```bash
# Assuming certificates are in ../workspace/vm-mesh-setup/vm-files/
VM_IP="20.1.2.3"

# Create directory and transfer
ssh azureuser@$VM_IP 'mkdir -p /tmp/vm-files'
scp -r ../workspace/vm-mesh-setup/vm-files/* azureuser@$VM_IP:/tmp/vm-files/

# Trigger boot-time configuration
ssh azureuser@$VM_IP 'sudo salt-call --local state.apply boot-time'
```

### Transfer Certificates to Multiple VMs

```bash
# Get all VM IPs
RESOURCE_GROUP="istio-playground-rg"
VM_PREFIX="istio-vm"

VM_IPS=($(az vm list -g $RESOURCE_GROUP \
  --query "[?starts_with(name, '$VM_PREFIX')].publicIps" -o tsv))

# Transfer to all VMs
for VM_IP in "${VM_IPS[@]}"; do
  echo "Transferring to $VM_IP..."
  ssh azureuser@$VM_IP 'mkdir -p /tmp/vm-files'
  scp -r ../workspace/vm-mesh-setup/vm-files/* azureuser@$VM_IP:/tmp/vm-files/
  ssh azureuser@$VM_IP 'sudo salt-call --local state.apply boot-time'
done
```

## Kubernetes Integration Examples

### Create WorkloadEntries for VMs

```bash
# Get VM information
RESOURCE_GROUP="istio-playground-rg" 
VM_PREFIX="istio-vm"
NAMESPACE="vm-workloads"

# Get VM names and IPs
VM_NAMES=($(az vm list -g $RESOURCE_GROUP \
  --query "[?starts_with(name, '$VM_PREFIX')].name" -o tsv))
VM_IPS=($(az vm list -g $RESOURCE_GROUP \
  --query "[?starts_with(name, '$VM_PREFIX')].publicIps" -o tsv))

# Create WorkloadEntry for each VM
for i in "${!VM_NAMES[@]}"; do
  VM_NAME="${VM_NAMES[$i]}"
  VM_IP="${VM_IPS[$i]}"
  
  kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  name: vm-web-service-${VM_NAME}
  namespace: $NAMESPACE
  labels:
    app: vm-web-service
spec:
  address: "$VM_IP"
  labels:
    app: vm-web-service
    version: v1.0
  serviceAccount: vm-workload
  network: "vm-network"
  ports:
    http: 8080
EOF
done
```

## Troubleshooting Examples

### Debug VM Configuration Issues

```bash
VM_IP="20.1.2.3"

# Check Salt logs
ssh azureuser@$VM_IP 'sudo tail -50 /var/log/salt/minion'

# Check boot logs  
ssh azureuser@$VM_IP 'sudo tail -50 /var/log/istio-boot.log'

# Check Istio service
ssh azureuser@$VM_IP 'sudo systemctl status istio'
ssh azureuser@$VM_IP 'sudo journalctl -u istio -n 20'

# Check network connectivity
ssh azureuser@$VM_IP 'curl -I http://localhost:15000/ready'
```

### Fix Common Issues

```bash
VM_IP="20.1.2.3"

# Restart Salt minion
ssh azureuser@$VM_IP 'sudo systemctl restart salt-minion'

# Re-run boot configuration
ssh azureuser@$VM_IP 'sudo salt-call --local state.apply boot-time'

# Check certificate permissions
ssh azureuser@$VM_IP 'ls -la /tmp/vm-files/ /etc/certs/ /var/run/secrets/tokens/'

# Restart Istio service
ssh azureuser@$VM_IP 'sudo systemctl restart istio'
```

## Monitoring Examples

### Continuous Health Monitoring

```bash
# Monitor all VMs continuously
while true; do
  echo "=== $(date) ==="
  ./check-all-vms.sh istio-playground-rg istio-vm
  sleep 60
done
```

### Collect Logs from All VMs

```bash
RESOURCE_GROUP="istio-playground-rg"
VM_PREFIX="istio-vm"
LOG_DIR="./vm-logs-$(date +%Y%m%d-%H%M%S)"

mkdir -p $LOG_DIR

# Get all VM IPs
VM_NAMES=($(az vm list -g $RESOURCE_GROUP \
  --query "[?starts_with(name, '$VM_PREFIX')].name" -o tsv))
VM_IPS=($(az vm list -g $RESOURCE_GROUP \
  --query "[?starts_with(name, '$VM_PREFIX')].publicIps" -o tsv))

# Collect logs from all VMs
for i in "${!VM_NAMES[@]}"; do
  VM_NAME="${VM_NAMES[$i]}"
  VM_IP="${VM_IPS[$i]}"
  
  echo "Collecting logs from $VM_NAME..."
  
  # Salt logs
  ssh azureuser@$VM_IP 'sudo cat /var/log/salt/minion' > $LOG_DIR/${VM_NAME}-salt.log
  
  # Boot logs
  ssh azureuser@$VM_IP 'sudo cat /var/log/istio-boot.log' > $LOG_DIR/${VM_NAME}-boot.log
  
  # Istio logs  
  ssh azureuser@$VM_IP 'sudo journalctl -u istio --no-pager' > $LOG_DIR/${VM_NAME}-istio.log
done

echo "Logs collected in: $LOG_DIR"
```

## Customization Examples

### Environment-Specific Configuration

Create different pillar files for different environments:

```bash
# Production pillar
cat > pillar-production.sls <<EOF
istio:
  version: "1.27.0"
environments:
  production:
    log_level: INFO
    health_check_interval: 60
EOF

# Development pillar  
cat > pillar-development.sls <<EOF
istio:
  version: "1.28.0"
environments:
  development:
    log_level: DEBUG
    health_check_interval: 15
EOF

# Use specific pillar during deployment
sudo cp pillar-production.sls /srv/pillar/top.sls
sudo salt-call --local state.apply boot-time
```

### Custom Salt States

```bash
# Create custom state for additional monitoring
cat > custom-monitoring.sls <<EOF
install_monitoring_tools:
  pkg.installed:
    - pkgs:
      - prometheus-node-exporter
      - grafana-agent

configure_node_exporter:
  service.running:
    - name: prometheus-node-exporter
    - enable: True
EOF

# Apply custom state
sudo cp custom-monitoring.sls /srv/salt/
sudo salt-call --local state.apply custom-monitoring
```

This examples file provides practical usage scenarios that users can copy and adapt for their specific needs.
