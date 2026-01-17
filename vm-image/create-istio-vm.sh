#!/bin/bash

# Enhanced Azure VM Creation Script with CloudInit for Istio Mesh Integration
# This script creates Azure VMs pre-configured for Istio service mesh integration
# Supports single VM and multiple VM deployment scenarios

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_section() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Default configuration
RESOURCE_GROUP="istio-playground-rg"
LOCATION="westus"
VM_PREFIX="istio-vm"
VM_COUNT=1
VM_SIZE="Standard_B2s"
IMAGE="Ubuntu2204"
ADMIN_USERNAME="azureuser"
CLOUD_INIT_FILE="cloud-init-istio-vm.yaml"
NETWORK_NAME="istio-vnet"
SUBNET_NAME="vm-subnet"
NSG_NAME="istio-vm-nsg"
PUBLIC_IP_TYPE="Standard"
AVAILABILITY_SET=""
CREATE_LOAD_BALANCER=false
DRY_RUN=false

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_INIT_PATH="${SCRIPT_DIR}/${CLOUD_INIT_FILE}"

# Function to display usage
usage() {
    cat << EOF
Azure VM Creation Script for Istio Mesh Integration

Usage: $0 [OPTIONS]

Options:
    -g, --resource-group NAME       Azure resource group (default: ${RESOURCE_GROUP})
    -l, --location REGION           Azure region (default: ${LOCATION})
    -n, --vm-name PREFIX            VM name prefix (default: ${VM_PREFIX})
    -c, --count NUMBER              Number of VMs to create (default: ${VM_COUNT})
    -s, --size VM_SIZE              Azure VM size (default: ${VM_SIZE})
    -i, --image IMAGE               VM image (default: ${IMAGE})
    -u, --admin-user USERNAME       Admin username (default: ${ADMIN_USERNAME})
    -f, --cloud-init-file FILE      CloudInit configuration file (default: ${CLOUD_INIT_FILE})
    --network-name NAME             Virtual network name (default: ${NETWORK_NAME})
    --subnet-name NAME              Subnet name (default: ${SUBNET_NAME})
    --nsg-name NAME                 Network security group name (default: ${NSG_NAME})
    --availability-set NAME         Availability set name (optional)
    --create-load-balancer          Create Azure Load Balancer for multiple VMs
    --dry-run                       Show what would be created without actually creating
    -h, --help                      Show this help message

Examples:
    # Create single VM with default settings
    $0

    # Create 3 VMs in specific resource group and region
    $0 -g my-istio-rg -l eastus -c 3

    # Create VMs with load balancer for production
    $0 -c 5 --create-load-balancer --size Standard_D2s_v3

    # Dry run to see what would be created
    $0 -c 3 --dry-run

Prerequisites:
    - Azure CLI installed and logged in
    - CloudInit file exists: ${CLOUD_INIT_FILE}
    - Appropriate permissions to create Azure resources

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            shift 2
            ;;
        -n|--vm-name)
            VM_PREFIX="$2"
            shift 2
            ;;
        -c|--count)
            VM_COUNT="$2"
            shift 2
            ;;
        -s|--size)
            VM_SIZE="$2"
            shift 2
            ;;
        -i|--image)
            IMAGE="$2"
            shift 2
            ;;
        -u|--admin-user)
            ADMIN_USERNAME="$2"
            shift 2
            ;;
        -f|--cloud-init-file)
            CLOUD_INIT_FILE="$2"
            CLOUD_INIT_PATH="${SCRIPT_DIR}/${CLOUD_INIT_FILE}"
            shift 2
            ;;
        --network-name)
            NETWORK_NAME="$2"
            shift 2
            ;;
        --subnet-name)
            SUBNET_NAME="$2"
            shift 2
            ;;
        --nsg-name)
            NSG_NAME="$2"
            shift 2
            ;;
        --availability-set)
            AVAILABILITY_SET="$2"
            shift 2
            ;;
        --create-load-balancer)
            CREATE_LOAD_BALANCER=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validation functions
validate_prerequisites() {
    print_section "Validating Prerequisites"
    
    # Check Azure CLI
    if ! command -v az &> /dev/null; then
        print_error "Azure CLI is not installed. Please install it first."
        exit 1
    fi
    
    # Check Azure login
    if ! az account show &> /dev/null; then
        print_error "Not logged into Azure. Please run 'az login' first."
        exit 1
    fi
    
    # Check CloudInit file
    if [ ! -f "$CLOUD_INIT_PATH" ]; then
        print_error "CloudInit file not found: $CLOUD_INIT_PATH"
        exit 1
    fi
    
    # Validate VM count
    if [ "$VM_COUNT" -lt 1 ] || [ "$VM_COUNT" -gt 100 ]; then
        print_error "VM count must be between 1 and 100"
        exit 1
    fi
    
    print_status "✓ Azure CLI is available and authenticated"
    print_status "✓ CloudInit file found: $CLOUD_INIT_PATH"
    print_status "✓ Configuration validated"
}

# Display configuration summary
show_configuration() {
    print_section "Configuration Summary"
    
    cat << EOF
Resource Group:     $RESOURCE_GROUP
Location:           $LOCATION
VM Name Prefix:     $VM_PREFIX
VM Count:           $VM_COUNT
VM Size:            $VM_SIZE
VM Image:           $IMAGE
Admin Username:     $ADMIN_USERNAME
CloudInit File:     $CLOUD_INIT_FILE
Network Name:       $NETWORK_NAME
Subnet Name:        $SUBNET_NAME
NSG Name:           $NSG_NAME
Load Balancer:      $([ "$CREATE_LOAD_BALANCER" = true ] && echo "Yes" || echo "No")
Availability Set:   ${AVAILABILITY_SET:-"None"}
Dry Run:            $([ "$DRY_RUN" = true ] && echo "Yes" || echo "No")
EOF
    
    if [ "$DRY_RUN" = false ]; then
        echo ""
        read -p "Continue with VM creation? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status "Operation cancelled"
            exit 0
        fi
    fi
}

# Create resource group
create_resource_group() {
    print_section "Creating Resource Group"
    
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would create resource group: $RESOURCE_GROUP"
        return
    fi
    
    if az group show --name "$RESOURCE_GROUP" &> /dev/null; then
        print_status "Resource group '$RESOURCE_GROUP' already exists"
    else
        print_status "Creating resource group: $RESOURCE_GROUP"
        az group create \
            --name "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --output table
    fi
}

# Create network resources
create_network_resources() {
    print_section "Creating Network Resources"
    
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would create virtual network: $NETWORK_NAME"
        print_status "[DRY RUN] Would create subnet: $SUBNET_NAME"
        print_status "[DRY RUN] Would create NSG: $NSG_NAME"
        return
    fi
    
    # Create Virtual Network
    if az network vnet show --resource-group "$RESOURCE_GROUP" --name "$NETWORK_NAME" &> /dev/null; then
        print_status "Virtual network '$NETWORK_NAME' already exists"
    else
        print_status "Creating virtual network: $NETWORK_NAME"
        az network vnet create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$NETWORK_NAME" \
            --address-prefix 10.1.0.0/16 \
            --subnet-name "$SUBNET_NAME" \
            --subnet-prefix 10.1.1.0/24 \
            --output table
    fi
    
    # Create Network Security Group
    if az network nsg show --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" &> /dev/null; then
        print_status "NSG '$NSG_NAME' already exists"
    else
        print_status "Creating Network Security Group: $NSG_NAME"
        az network nsg create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$NSG_NAME" \
            --output table
        
        # Create NSG rules for Istio mesh
        print_status "Creating NSG rules for Istio mesh traffic..."
        
        # SSH
        az network nsg rule create \
            --resource-group "$RESOURCE_GROUP" \
            --nsg-name "$NSG_NAME" \
            --name "SSH" \
            --priority 1000 \
            --source-address-prefixes '*' \
            --source-port-ranges '*' \
            --destination-address-prefixes '*' \
            --destination-port-ranges 22 \
            --access Allow \
            --protocol Tcp \
            --description "SSH access" \
            --output table
        
        # VM Web Service
        az network nsg rule create \
            --resource-group "$RESOURCE_GROUP" \
            --nsg-name "$NSG_NAME" \
            --name "VMWebService" \
            --priority 1010 \
            --source-address-prefixes '*' \
            --source-port-ranges '*' \
            --destination-address-prefixes '*' \
            --destination-port-ranges 8080 \
            --access Allow \
            --protocol Tcp \
            --description "VM web service" \
            --output table
        
        # Istio sidecar ports
        az network nsg rule create \
            --resource-group "$RESOURCE_GROUP" \
            --nsg-name "$NSG_NAME" \
            --name "IstioSidecar" \
            --priority 1020 \
            --source-address-prefixes '*' \
            --source-port-ranges '*' \
            --destination-address-prefixes '*' \
            --destination-port-ranges 15000-15090 \
            --access Allow \
            --protocol Tcp \
            --description "Istio sidecar ports" \
            --output table
        
        # Associate NSG with subnet
        az network vnet subnet update \
            --resource-group "$RESOURCE_GROUP" \
            --vnet-name "$NETWORK_NAME" \
            --name "$SUBNET_NAME" \
            --network-security-group "$NSG_NAME" \
            --output table
    fi
}

# Create availability set
create_availability_set() {
    if [ -n "$AVAILABILITY_SET" ]; then
        print_section "Creating Availability Set"
        
        if [ "$DRY_RUN" = true ]; then
            print_status "[DRY RUN] Would create availability set: $AVAILABILITY_SET"
            return
        fi
        
        if az vm availability-set show --resource-group "$RESOURCE_GROUP" --name "$AVAILABILITY_SET" &> /dev/null; then
            print_status "Availability set '$AVAILABILITY_SET' already exists"
        else
            print_status "Creating availability set: $AVAILABILITY_SET"
            az vm availability-set create \
                --resource-group "$RESOURCE_GROUP" \
                --name "$AVAILABILITY_SET" \
                --platform-fault-domain-count 2 \
                --platform-update-domain-count 5 \
                --output table
        fi
    fi
}

# Create load balancer (for multiple VMs)
create_load_balancer() {
    if [ "$CREATE_LOAD_BALANCER" = true ] && [ "$VM_COUNT" -gt 1 ]; then
        print_section "Creating Load Balancer"
        
        local lb_name="${VM_PREFIX}-lb"
        local backend_pool_name="${VM_PREFIX}-backend-pool"
        local health_probe_name="${VM_PREFIX}-health-probe"
        local lb_rule_name="${VM_PREFIX}-lb-rule"
        
        if [ "$DRY_RUN" = true ]; then
            print_status "[DRY RUN] Would create load balancer: $lb_name"
            return
        fi
        
        if az network lb show --resource-group "$RESOURCE_GROUP" --name "$lb_name" &> /dev/null; then
            print_status "Load balancer '$lb_name' already exists"
        else
            print_status "Creating load balancer: $lb_name"
            
            # Create public IP for load balancer
            az network public-ip create \
                --resource-group "$RESOURCE_GROUP" \
                --name "${lb_name}-ip" \
                --sku Standard \
                --allocation-method Static \
                --output table
            
            # Create load balancer
            az network lb create \
                --resource-group "$RESOURCE_GROUP" \
                --name "$lb_name" \
                --sku Standard \
                --public-ip-address "${lb_name}-ip" \
                --frontend-ip-name "${lb_name}-frontend" \
                --backend-pool-name "$backend_pool_name" \
                --output table
            
            # Create health probe
            az network lb probe create \
                --resource-group "$RESOURCE_GROUP" \
                --lb-name "$lb_name" \
                --name "$health_probe_name" \
                --protocol Http \
                --port 8080 \
                --path /health \
                --interval 15 \
                --threshold 2 \
                --output table
            
            # Create load balancer rule
            az network lb rule create \
                --resource-group "$RESOURCE_GROUP" \
                --lb-name "$lb_name" \
                --name "$lb_rule_name" \
                --protocol Tcp \
                --frontend-port 8080 \
                --backend-port 8080 \
                --frontend-ip-name "${lb_name}-frontend" \
                --backend-pool-name "$backend_pool_name" \
                --probe-name "$health_probe_name" \
                --idle-timeout 15 \
                --enable-floating-ip false \
                --output table
        fi
    fi
}

# Create VMs
create_vms() {
    print_section "Creating Virtual Machines"
    
    local vm_names=()
    local vm_ips=()
    
    # Generate VM names
    if [ "$VM_COUNT" -eq 1 ]; then
        vm_names=("$VM_PREFIX")
    else
        for i in $(seq 1 "$VM_COUNT"); do
            vm_names+=("${VM_PREFIX}-$(printf "%02d" "$i")")
        done
    fi
    
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would create the following VMs:"
        for vm_name in "${vm_names[@]}"; do
            print_status "  - $vm_name (Size: $VM_SIZE, Image: $IMAGE)"
        done
        return
    fi
    
    # Create VMs in parallel for better performance
    local pids=()
    
    for vm_name in "${vm_names[@]}"; do
        {
            print_status "Creating VM: $vm_name"
            
            # Build VM creation command
            local vm_cmd=(
                az vm create
                --resource-group "$RESOURCE_GROUP"
                --name "$vm_name"
                --image "$IMAGE"
                --size "$VM_SIZE"
                --admin-username "$ADMIN_USERNAME"
                --generate-ssh-keys
                --vnet-name "$NETWORK_NAME"
                --subnet "$SUBNET_NAME"
                --nsg "$NSG_NAME"
                --public-ip-sku "$PUBLIC_IP_TYPE"
                --custom-data "$CLOUD_INIT_PATH"
                --output json
            )
            
            # Add availability set if specified
            if [ -n "$AVAILABILITY_SET" ]; then
                vm_cmd+=(--availability-set "$AVAILABILITY_SET")
            fi
            
            # Create VM
            local result
            if result=$("${vm_cmd[@]}" 2>&1); then
                local vm_ip
                vm_ip=$(echo "$result" | jq -r '.publicIpAddress')
                print_status "✓ VM '$vm_name' created successfully (IP: $vm_ip)"
                echo "$vm_name:$vm_ip" >> "/tmp/vm_creation_results.txt"
            else
                print_error "Failed to create VM '$vm_name': $result"
                echo "$vm_name:ERROR" >> "/tmp/vm_creation_results.txt"
            fi
        } &
        pids+=($!)
    done
    
    # Wait for all VMs to be created
    print_status "Waiting for all VMs to be created..."
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    # Process results
    if [ -f "/tmp/vm_creation_results.txt" ]; then
        print_status "VM Creation Results:"
        while IFS=':' read -r vm_name vm_ip; do
            if [ "$vm_ip" = "ERROR" ]; then
                print_error "  ❌ $vm_name: Creation failed"
            else
                print_status "  ✅ $vm_name: $vm_ip"
                vm_ips+=("$vm_ip")
            fi
        done < "/tmp/vm_creation_results.txt"
        rm -f "/tmp/vm_creation_results.txt"
    fi
}

# Add VMs to load balancer backend pool
add_vms_to_load_balancer() {
    if [ "$CREATE_LOAD_BALANCER" = true ] && [ "$VM_COUNT" -gt 1 ] && [ "$DRY_RUN" = false ]; then
        print_section "Adding VMs to Load Balancer"
        
        local lb_name="${VM_PREFIX}-lb"
        local backend_pool_name="${VM_PREFIX}-backend-pool"
        
        # Generate VM names again
        local vm_names=()
        for i in $(seq 1 "$VM_COUNT"); do
            vm_names+=("${VM_PREFIX}-$(printf "%02d" "$i")")
        done
        
        for vm_name in "${vm_names[@]}"; do
            print_status "Adding $vm_name to load balancer backend pool"
            
            local nic_name="${vm_name}VMNic"
            az network nic ip-config address-pool add \
                --resource-group "$RESOURCE_GROUP" \
                --nic-name "$nic_name" \
                --ip-config-name "ipconfigVM" \
                --lb-name "$lb_name" \
                --address-pool "$backend_pool_name" \
                --output table || true
        done
    fi
}

# Display completion summary
show_completion_summary() {
    print_section "Deployment Summary"
    
    if [ "$DRY_RUN" = true ]; then
        print_status "Dry run completed. No resources were created."
        return
    fi
    
    print_status "✅ VM deployment completed successfully!"
    echo ""
    
    print_status "📋 Created Resources:"
    print_status "  • Resource Group: $RESOURCE_GROUP"
    print_status "  • Virtual Network: $NETWORK_NAME"
    print_status "  • Network Security Group: $NSG_NAME"
    if [ -n "$AVAILABILITY_SET" ]; then
        print_status "  • Availability Set: $AVAILABILITY_SET"
    fi
    if [ "$CREATE_LOAD_BALANCER" = true ] && [ "$VM_COUNT" -gt 1 ]; then
        print_status "  • Load Balancer: ${VM_PREFIX}-lb"
    fi
    print_status "  • Virtual Machine(s): $VM_COUNT VM(s) created"
    
    echo ""
    print_status "📡 Next Steps:"
    print_status "1. Wait 3-5 minutes for cloud-init to complete on all VMs"
    print_status "2. Verify VM readiness:"
    if [ -f "/tmp/vm_creation_results.txt" ]; then
        while IFS=':' read -r vm_name vm_ip; do
            if [ "$vm_ip" != "ERROR" ]; then
                print_status "   ssh $ADMIN_USERNAME@$vm_ip './check-service.sh'"
            fi
        done < "/tmp/vm_creation_results.txt"
    fi
    print_status "3. Set up Istio mesh integration using the mesh integration script"
    print_status "4. Create WorkloadEntry resources in your Kubernetes cluster"
    
    echo ""
    print_status "📚 Useful Commands:"
    print_status "   View VMs: az vm list -g $RESOURCE_GROUP --output table"
    if [ "$CREATE_LOAD_BALANCER" = true ] && [ "$VM_COUNT" -gt 1 ]; then
        print_status "   Load Balancer IP: az network public-ip show -g $RESOURCE_GROUP -n ${VM_PREFIX}-lb-ip --query ipAddress -o tsv"
    fi
    print_status "   VM Status: az vm list -g $RESOURCE_GROUP -d --output table"
}

# Main execution
main() {
    print_section "Azure VM Creation for Istio Mesh Integration"
    
    validate_prerequisites
    show_configuration
    create_resource_group
    create_network_resources
    create_availability_set
    create_load_balancer
    create_vms
    add_vms_to_load_balancer
    show_completion_summary
    
    print_status "🎉 Script execution completed!"
}

# Execute main function
main "$@"