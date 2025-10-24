#!/bin/bash
# Script to check health of all deployed VMs

set -e

RESOURCE_GROUP="${1:-istio-playground-rg}"
VM_PREFIX="${2:-istio-vm}"

print_status() {
    echo -e "\033[0;32m[INFO]\033[0m $1"
}

print_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1"
}

print_warning() {
    echo -e "\033[1;33m[WARNING]\033[0m $1"
}

print_status "Checking health of all VMs with prefix: $VM_PREFIX"

# Get all VMs with the specified prefix
VM_NAMES=($(az vm list --resource-group $RESOURCE_GROUP --query "[?starts_with(name, '$VM_PREFIX')].name" -o tsv))
VM_IPS=($(az vm list --resource-group $RESOURCE_GROUP --query "[?starts_with(name, '$VM_PREFIX')].publicIps" -o tsv))

if [ ${#VM_NAMES[@]} -eq 0 ]; then
    print_error "No VMs found with prefix '$VM_PREFIX' in resource group '$RESOURCE_GROUP'"
    exit 1
fi

print_status "Found ${#VM_NAMES[@]} VMs to check"
print_status "============================================="

HEALTHY_COUNT=0
UNHEALTHY_VMS=()

# Check each VM
for i in "${!VM_NAMES[@]}"; do
    VM_NAME="${VM_NAMES[$i]}"
    VM_IP="${VM_IPS[$i]}"
    
    echo ""
    print_status "Checking VM: $VM_NAME ($VM_IP)"
    
    # Check SSH connectivity
    if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no azureuser@$VM_IP 'echo "SSH OK"' >/dev/null 2>&1; then
        print_error "  ✗ SSH connectivity failed"
        UNHEALTHY_VMS+=($VM_NAME)
        continue
    fi
    
    # Check if health check script exists
    if ! ssh azureuser@$VM_IP 'test -f ./check-service.sh'; then
        print_error "  ✗ Health check script not found"
        UNHEALTHY_VMS+=($VM_NAME)
        continue
    fi
    
    # Run health check
    if ssh azureuser@$VM_IP './check-service.sh' >/dev/null 2>&1; then
        print_status "  ✅ Health check passed"
        
        # Check Salt minion status
        SALT_STATUS=$(ssh azureuser@$VM_IP 'sudo systemctl is-active salt-minion 2>/dev/null || echo "inactive"')
        if [ "$SALT_STATUS" = "active" ]; then
            print_status "  ✅ Salt minion is running"
        else
            print_warning "  ⚠️ Salt minion is not running ($SALT_STATUS)"
        fi
        
        # Check Istio service status
        ISTIO_STATUS=$(ssh azureuser@$VM_IP 'sudo systemctl is-active istio 2>/dev/null || echo "inactive"')
        if [ "$ISTIO_STATUS" = "active" ]; then
            print_status "  ✅ Istio service is running"
        else
            print_warning "  ⚠️ Istio service is not running ($ISTIO_STATUS)"
        fi
        
        # Check admin interface
        if ssh azureuser@$VM_IP 'curl -s --connect-timeout 2 http://localhost:15000/ready >/dev/null 2>&1'; then
            print_status "  ✅ Istio admin interface accessible"
        else
            print_warning "  ⚠️ Istio admin interface not accessible"
        fi
        
        HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
    else
        print_error "  ✗ Health check failed"
        UNHEALTHY_VMS+=($VM_NAME)
    fi
done

echo ""
print_status "============================================="
print_status "Health Check Summary"
print_status "============================================="
print_status "Total VMs: ${#VM_NAMES[@]}"
print_status "Healthy VMs: $HEALTHY_COUNT"
print_status "Unhealthy VMs: ${#UNHEALTHY_VMS[@]}"

if [ ${#UNHEALTHY_VMS[@]} -gt 0 ]; then
    print_warning ""
    print_warning "Unhealthy VMs:"
    for vm in "${UNHEALTHY_VMS[@]}"; do
        print_warning "  - $vm"
    done
    
    echo ""
    print_status "Troubleshooting steps for unhealthy VMs:"
    print_status "1. Check VM logs: ssh azureuser@VM_IP 'sudo journalctl -u salt-minion -n 20'"
    print_status "2. Check boot logs: ssh azureuser@VM_IP 'sudo tail -20 /var/log/istio-boot.log'"
    print_status "3. Manually run boot-time config: ssh azureuser@VM_IP 'sudo salt-call --local state.apply boot-time'"
    print_status "4. Transfer certificates if missing: scp -r vm-files/* azureuser@VM_IP:/tmp/vm-files/"
fi

echo ""
if [ $HEALTHY_COUNT -eq ${#VM_NAMES[@]} ]; then
    print_status "🎉 All VMs are healthy!"
    exit 0
else
    print_error "❌ Some VMs require attention"
    exit 1
fi