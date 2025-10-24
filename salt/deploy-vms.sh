#!/bin/bash
# Script to deploy VMs from Salt-configured image

set -e

RESOURCE_GROUP="${1:-istio-playground-rg}"
IMAGE_NAME="${2:-istio-vm-image}"
VM_PREFIX="${3:-istio-vm}"
VM_COUNT="${4:-1}"
VM_SIZE="${5:-Standard_B2s}"

print_status() {
    echo -e "\033[0;32m[INFO]\033[0m $1"
}

print_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1"
}

print_status "Deploying VMs from Salt-configured image"
print_status "Resource Group: $RESOURCE_GROUP"
print_status "Image: $IMAGE_NAME"
print_status "VM Prefix: $VM_PREFIX"
print_status "VM Count: $VM_COUNT"

# Verify image exists
if ! az image show --resource-group $RESOURCE_GROUP --name $IMAGE_NAME >/dev/null 2>&1; then
    print_error "Image $IMAGE_NAME not found in resource group $RESOURCE_GROUP"
    exit 1
fi

# Create VMs
VM_NAMES=()
for i in $(seq 1 $VM_COUNT); do
    VM_NAME="${VM_PREFIX}-${i}"
    VM_NAMES+=($VM_NAME)
    
    print_status "Creating VM: $VM_NAME"
    
    az vm create \
        --resource-group $RESOURCE_GROUP \
        --name $VM_NAME \
        --image $IMAGE_NAME \
        --admin-username azureuser \
        --generate-ssh-keys \
        --size $VM_SIZE \
        --no-wait \
        --public-ip-sku Standard
done

# Wait for all VMs to be ready
print_status "Waiting for VMs to be created..."
sleep 60

# Get VM IPs
VM_IPS=()
for VM_NAME in "${VM_NAMES[@]}"; do
    print_status "Getting IP for VM: $VM_NAME"
    VM_IP=$(az vm show -d --resource-group $RESOURCE_GROUP --name $VM_NAME --query publicIps -o tsv)
    VM_IPS+=($VM_IP)
    print_status "VM $VM_NAME IP: $VM_IP"
done

# Wait for VMs to be SSH-accessible
print_status "Waiting for VMs to be SSH-accessible..."
for i in "${!VM_NAMES[@]}"; do
    VM_NAME="${VM_NAMES[$i]}"
    VM_IP="${VM_IPS[$i]}"
    
    print_status "Checking SSH connectivity to $VM_NAME ($VM_IP)..."
    for attempt in {1..30}; do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no azureuser@$VM_IP 'echo "SSH Ready"' >/dev/null 2>&1; then
            print_status "✓ $VM_NAME is SSH accessible"
            break
        fi
        if [ $attempt -eq 30 ]; then
            print_error "✗ $VM_NAME failed to become SSH accessible after 5 minutes"
        else
            sleep 10
        fi
    done
done

# Check if VM files directory exists (certificates and config)
VM_FILES_DIR="../workspace/vm-mesh-setup/vm-files"
if [ -d "$VM_FILES_DIR" ]; then
    print_status "Found VM files directory, transferring certificates..."
    
    # Transfer certificates to all VMs
    for i in "${!VM_NAMES[@]}"; do
        VM_NAME="${VM_NAMES[$i]}"
        VM_IP="${VM_IPS[$i]}"
        
        print_status "Transferring certificates to $VM_NAME..."
        
        # Create directory and transfer files
        ssh -o StrictHostKeyChecking=no azureuser@$VM_IP 'mkdir -p /tmp/vm-files'
        scp -o StrictHostKeyChecking=no -r $VM_FILES_DIR/* azureuser@$VM_IP:/tmp/vm-files/
        
        print_status "✓ Certificates transferred to $VM_NAME"
    done
    
    # Wait a bit for boot-time Salt state to run
    print_status "Waiting for boot-time configuration to complete..."
    sleep 30
    
    # Verify health of all VMs
    print_status "Checking VM health..."
    for i in "${!VM_NAMES[@]}"; do
        VM_NAME="${VM_NAMES[$i]}"
        VM_IP="${VM_IPS[$i]}"
        
        print_status "Health check for $VM_NAME..."
        if ssh azureuser@$VM_IP './check-service.sh' >/dev/null 2>&1; then
            print_status "✅ $VM_NAME is healthy and mesh-integrated"
        else
            print_error "⚠️ $VM_NAME has health issues"
            # Try to manually run boot-time configuration
            print_status "Attempting manual configuration for $VM_NAME..."
            ssh azureuser@$VM_IP 'sudo salt-call --local state.apply boot-time'
        fi
    done
else
    print_status "⚠️ VM files directory not found at $VM_FILES_DIR"
    print_status "VMs are created but mesh integration certificates need to be transferred manually"
    print_status "After transferring certificates to /tmp/vm-files/, run: sudo salt-call --local state.apply boot-time"
fi

# Summary
print_status ""
print_status "=== Deployment Summary ==="
print_status "Resource Group: $RESOURCE_GROUP"
print_status "VMs Created: ${#VM_NAMES[@]}"
print_status ""

for i in "${!VM_NAMES[@]}"; do
    VM_NAME="${VM_NAMES[$i]}"
    VM_IP="${VM_IPS[$i]}"
    print_status "VM: $VM_NAME - IP: $VM_IP"
done

print_status ""
print_status "✅ VM deployment completed!"
print_status ""
print_status "Next steps:"
print_status "1. Verify all VMs are healthy: ./check-all-vms.sh"
print_status "2. Create WorkloadEntries in Kubernetes cluster"
print_status "3. Test mesh connectivity"