#!/bin/bash

# Azure VM Image Creation Script for Istio-Ready VMs
# This script creates custom Azure VM images from VMs configured for Istio mesh integration
# The resulting images can be reused to quickly deploy pre-configured Istio-ready VMs

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
RESOURCE_GROUP=""
VM_NAME=""
IMAGE_NAME=""
IMAGE_VERSION="1.0.0"
IMAGE_GALLERY=""
TARGET_RESOURCE_GROUP=""
LOCATION=""
PREPARE_VM=true
CLEANUP_VM=false
DRY_RUN=false
HYPER_V_GENERATION="V2"
OS_TYPE="Linux"
OS_STATE="Generalized"

# Function to display usage
usage() {
    cat << EOF
Azure VM Image Creation Script for Istio-Ready VMs

Usage: $0 [OPTIONS]

Required Options:
    -g, --resource-group NAME       Resource group containing the source VM
    -v, --vm-name NAME              Name of the source VM to create image from
    -i, --image-name NAME           Name for the new VM image

Optional Options:
    --image-version VERSION         Image version (default: ${IMAGE_VERSION})
    --image-gallery NAME            Azure Compute Gallery name (for managed images)
    --target-resource-group NAME    Target resource group for image (defaults to source RG)
    --location REGION               Azure region (auto-detected from VM if not specified)
    --no-prepare                    Skip VM preparation (sysprep/waagent deprovision)
    --cleanup-vm                    Delete the source VM after image creation
    --hyper-v-generation GEN        Hyper-V generation V1 or V2 (default: ${HYPER_V_GENERATION})
    --dry-run                       Show what would be done without executing
    -h, --help                      Show this help message

Image Creation Process:
    1. Validate prerequisites and VM readiness
    2. Prepare VM for imaging (generalization)
    3. Deallocate the VM
    4. Create VM image or managed image
    5. Optionally cleanup source VM
    6. Provide deployment examples

Examples:
    # Basic image creation
    $0 -g istio-playground-rg -v istio-vm-01 -i istio-ready-vm-image

    # Create versioned image in gallery
    $0 -g istio-playground-rg -v istio-vm-01 -i istio-ready-vm \\
       --image-gallery MyIstioGallery --image-version 1.2.0

    # Full workflow with cleanup
    $0 -g istio-playground-rg -v istio-vm-01 -i istio-ready-vm \\
       --cleanup-vm --target-resource-group istio-images-rg

    # Dry run to preview actions
    $0 -g istio-playground-rg -v istio-vm-01 -i istio-ready-vm --dry-run

Prerequisites:
    - Azure CLI installed and logged in
    - Source VM exists and is properly configured
    - Appropriate permissions to create images and modify VMs

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -v|--vm-name)
            VM_NAME="$2"
            shift 2
            ;;
        -i|--image-name)
            IMAGE_NAME="$2"
            shift 2
            ;;
        --image-version)
            IMAGE_VERSION="$2"
            shift 2
            ;;
        --image-gallery)
            IMAGE_GALLERY="$2"
            shift 2
            ;;
        --target-resource-group)
            TARGET_RESOURCE_GROUP="$2"
            shift 2
            ;;
        --location)
            LOCATION="$2"
            shift 2
            ;;
        --no-prepare)
            PREPARE_VM=false
            shift
            ;;
        --cleanup-vm)
            CLEANUP_VM=true
            shift
            ;;
        --hyper-v-generation)
            HYPER_V_GENERATION="$2"
            shift 2
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

# Validate required parameters
if [ -z "$RESOURCE_GROUP" ] || [ -z "$VM_NAME" ] || [ -z "$IMAGE_NAME" ]; then
    print_error "Required parameters missing. Use -h for help."
    exit 1
fi

# Set defaults
TARGET_RESOURCE_GROUP="${TARGET_RESOURCE_GROUP:-$RESOURCE_GROUP}"

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
    
    # Check if VM exists
    if ! az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" &> /dev/null; then
        print_error "VM '$VM_NAME' not found in resource group '$RESOURCE_GROUP'"
        exit 1
    fi
    
    # Get VM location if not specified
    if [ -z "$LOCATION" ]; then
        LOCATION=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query location -o tsv)
        print_status "Auto-detected location: $LOCATION"
    fi
    
    # Check if target resource group exists
    if [ "$TARGET_RESOURCE_GROUP" != "$RESOURCE_GROUP" ]; then
        if ! az group show --name "$TARGET_RESOURCE_GROUP" &> /dev/null; then
            if [ "$DRY_RUN" = false ]; then
                print_status "Creating target resource group: $TARGET_RESOURCE_GROUP"
                az group create --name "$TARGET_RESOURCE_GROUP" --location "$LOCATION"
            else
                print_status "[DRY RUN] Would create resource group: $TARGET_RESOURCE_GROUP"
            fi
        fi
    fi
    
    # Check if image gallery exists (if specified)
    if [ -n "$IMAGE_GALLERY" ]; then
        if ! az sig show --resource-group "$TARGET_RESOURCE_GROUP" --gallery-name "$IMAGE_GALLERY" &> /dev/null; then
            print_warning "Compute Gallery '$IMAGE_GALLERY' does not exist. It will be created."
        fi
    fi
    
    print_status "✓ Prerequisites validated"
}

# Display configuration summary
show_configuration() {
    print_section "Configuration Summary"
    
    local vm_status
    vm_status=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --show-details --query powerState -o tsv)
    
    cat << EOF
Source VM:              $VM_NAME (Status: $vm_status)
Source Resource Group:  $RESOURCE_GROUP
Image Name:             $IMAGE_NAME
Image Version:          $IMAGE_VERSION
Target Resource Group:  $TARGET_RESOURCE_GROUP
Location:               $LOCATION
Image Gallery:          ${IMAGE_GALLERY:-"Standard Image (not using gallery)"}
Hyper-V Generation:     $HYPER_V_GENERATION
Prepare VM:             $([ "$PREPARE_VM" = true ] && echo "Yes" || echo "No")
Cleanup Source VM:      $([ "$CLEANUP_VM" = true ] && echo "Yes" || echo "No")
Dry Run:                $([ "$DRY_RUN" = true ] && echo "Yes" || echo "No")
EOF
    
    if [ "$DRY_RUN" = false ]; then
        echo ""
        print_warning "⚠️  This will generalize and potentially delete the source VM!"
        read -p "Continue with image creation? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status "Operation cancelled"
            exit 0
        fi
    fi
}

# Check VM readiness for imaging
check_vm_readiness() {
    print_section "Checking VM Readiness"
    
    local vm_status
    vm_status=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --show-details --query powerState -o tsv)
    
    print_status "VM Status: $vm_status"
    
    if [ "$vm_status" != "VM running" ] && [ "$vm_status" != "VM stopped" ]; then
        print_error "VM is in an unexpected state: $vm_status"
        print_error "Please ensure VM is in 'running' or 'stopped' state before imaging"
        exit 1
    fi
    
    # If VM is running and we need to prepare it, we'll need SSH access
    if [ "$vm_status" = "VM running" ] && [ "$PREPARE_VM" = true ]; then
        print_status "VM is running and will be prepared for imaging"
        
        # Get VM IP for connection test
        local vm_ip
        vm_ip=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --show-details --query publicIps -o tsv)
        
        if [ -n "$vm_ip" ] && [ "$vm_ip" != "null" ]; then
            print_status "VM Public IP: $vm_ip"
            
            if [ "$DRY_RUN" = false ]; then
                # Test SSH connectivity
                print_status "Testing SSH connectivity..."
                if timeout 10 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "azureuser@$vm_ip" "echo 'SSH connection successful'" &> /dev/null; then
                    print_status "✓ SSH connectivity verified"
                else
                    print_warning "⚠️  SSH connectivity test failed. VM preparation may fail."
                fi
            fi
        else
            print_warning "⚠️  VM does not have a public IP. VM preparation may not be possible."
        fi
    fi
    
    print_status "✓ VM readiness check completed"
}

# Prepare VM for imaging (generalization)
prepare_vm() {
    if [ "$PREPARE_VM" = false ]; then
        print_status "Skipping VM preparation (--no-prepare specified)"
        return
    fi
    
    print_section "Preparing VM for Imaging"
    
    local vm_status
    vm_status=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --show-details --query powerState -o tsv)
    
    if [ "$vm_status" != "VM running" ]; then
        print_status "Starting VM for preparation..."
        if [ "$DRY_RUN" = false ]; then
            az vm start --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"
            sleep 30  # Wait for VM to fully start
        else
            print_status "[DRY RUN] Would start VM: $VM_NAME"
        fi
    fi
    
    # Get VM IP
    local vm_ip
    if [ "$DRY_RUN" = false ]; then
        vm_ip=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --show-details --query publicIps -o tsv)
    else
        vm_ip="<VM_IP>"
    fi
    
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would prepare VM for imaging:"
        print_status "[DRY RUN]   - Clean cloud-init state"
        print_status "[DRY RUN]   - Clear bash history and logs"
        print_status "[DRY RUN]   - Run waagent deprovision"
        print_status "[DRY RUN]   - Shutdown VM"
        return
    fi
    
    print_status "Connecting to VM ($vm_ip) to prepare for imaging..."
    
    # Create preparation script
    local prep_script="/tmp/prepare_vm_for_imaging.sh"
    cat > "$prep_script" << 'EOF'
#!/bin/bash
# VM Preparation script for Azure image creation

set -e

echo "🔧 Preparing VM for imaging..."

# Stop services that might interfere with generalization
echo "Stopping services..."
sudo systemctl stop vm-web-service.service || true
sudo systemctl stop istio.service || true

# Clean cloud-init state
echo "Cleaning cloud-init state..."
sudo cloud-init clean --logs
sudo rm -rf /var/lib/cloud/instances/*
sudo rm -f /var/lib/cloud/instance

# Clean logs and temporary files
echo "Cleaning logs and temporary files..."
sudo rm -rf /var/log/*
sudo rm -rf /tmp/*
sudo rm -rf /var/tmp/*

# Clear bash history
echo "Clearing bash history..."
history -c
cat /dev/null > ~/.bash_history
sudo cat /dev/null > /root/.bash_history || true

# Remove SSH host keys (they will be regenerated)
echo "Removing SSH host keys..."
sudo rm -f /etc/ssh/ssh_host_*

# Clear machine-id
echo "Clearing machine-id..."
sudo truncate -s 0 /etc/machine-id

# Clean package cache
echo "Cleaning package cache..."
sudo apt-get clean || true
sudo apt-get autoremove -y || true

# Remove any mesh-specific runtime state but preserve installed components
echo "Cleaning mesh runtime state..."
sudo rm -rf /tmp/vm-files || true
sudo rm -f /etc/certs/root-cert.pem || true
sudo rm -f /var/run/secrets/istio/root-cert.pem || true
sudo rm -f /var/run/secrets/tokens/istio-token || true
sudo rm -f /etc/istio/config/mesh || true
sudo rm -f /var/lib/istio/envoy/cluster.env || true

# Restore default hosts file entries (remove Istio-specific entries)
sudo sed -i '/istiod/d' /etc/hosts || true

echo "✓ VM preparation completed"
echo "VM is ready for generalization and imaging"
EOF
    
    # Execute preparation script on VM
    print_status "Executing preparation script on VM..."
    if scp -o StrictHostKeyChecking=no "$prep_script" "azureuser@$vm_ip:/tmp/prepare_vm.sh" && \
       ssh -o StrictHostKeyChecking=no "azureuser@$vm_ip" "chmod +x /tmp/prepare_vm.sh && /tmp/prepare_vm.sh"; then
        print_status "✓ VM preparation script executed successfully"
    else
        print_error "Failed to execute preparation script"
        exit 1
    fi
    
    # Run waagent deprovision
    print_status "Running waagent deprovision..."
    if ssh -o StrictHostKeyChecking=no "azureuser@$vm_ip" "sudo waagent -deprovision+user -force"; then
        print_status "✓ waagent deprovision completed"
    else
        print_error "waagent deprovision failed"
        exit 1
    fi
    
    print_status "✓ VM prepared for imaging"
}

# Deallocate VM
deallocate_vm() {
    print_section "Deallocating VM"
    
    local vm_status
    vm_status=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --show-details --query powerState -o tsv)
    
    if [ "$vm_status" = "VM deallocated" ]; then
        print_status "VM is already deallocated"
        return
    fi
    
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would deallocate VM: $VM_NAME"
        return
    fi
    
    print_status "Deallocating VM: $VM_NAME"
    az vm deallocate --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"
    
    print_status "Generalizing VM: $VM_NAME"
    az vm generalize --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"
    
    print_status "✓ VM deallocated and generalized"
}

# Create VM image
create_vm_image() {
    print_section "Creating VM Image"
    
    if [ "$DRY_RUN" = true ]; then
        if [ -n "$IMAGE_GALLERY" ]; then
            print_status "[DRY RUN] Would create managed image in gallery: $IMAGE_GALLERY"
            print_status "[DRY RUN]   Image definition: $IMAGE_NAME"
            print_status "[DRY RUN]   Image version: $IMAGE_VERSION"
        else
            print_status "[DRY RUN] Would create standard image: $IMAGE_NAME"
        fi
        return
    fi
    
    if [ -n "$IMAGE_GALLERY" ]; then
        # Create image in Compute Gallery (managed image)
        create_managed_image
    else
        # Create standard VM image
        create_standard_image
    fi
}

# Create standard VM image
create_standard_image() {
    print_status "Creating standard VM image: $IMAGE_NAME"
    
    # Check if image already exists
    if az image show --resource-group "$TARGET_RESOURCE_GROUP" --name "$IMAGE_NAME" &> /dev/null; then
        print_warning "Image '$IMAGE_NAME' already exists"
        read -p "Overwrite existing image? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status "Keeping existing image"
            return
        fi
        print_status "Deleting existing image..."
        az image delete --resource-group "$TARGET_RESOURCE_GROUP" --name "$IMAGE_NAME"
    fi
    
    print_status "Creating image from VM..."
    az image create \
        --resource-group "$TARGET_RESOURCE_GROUP" \
        --name "$IMAGE_NAME" \
        --location "$LOCATION" \
        --source "$VM_NAME" \
        --source-resource-group "$RESOURCE_GROUP" \
        --hyper-v-generation "$HYPER_V_GENERATION" \
        --os-type "$OS_TYPE" \
        --os-state "$OS_STATE" \
        --tags "created-by=istio-vm-image-script" \
               "source-vm=$VM_NAME" \
               "istio-ready=true" \
               "created-date=$(date -u +%Y-%m-%d)" \
        --output table
    
    print_status "✓ Standard VM image created successfully"
}

# Create managed image in Compute Gallery
create_managed_image() {
    print_status "Creating managed image in Compute Gallery: $IMAGE_GALLERY"
    
    # Create gallery if it doesn't exist
    if ! az sig show --resource-group "$TARGET_RESOURCE_GROUP" --gallery-name "$IMAGE_GALLERY" &> /dev/null; then
        print_status "Creating Compute Gallery: $IMAGE_GALLERY"
        az sig create \
            --resource-group "$TARGET_RESOURCE_GROUP" \
            --gallery-name "$IMAGE_GALLERY" \
            --location "$LOCATION" \
            --description "Istio-ready VM images for service mesh integration"
    fi
    
    # Create image definition if it doesn't exist
    if ! az sig image-definition show \
        --resource-group "$TARGET_RESOURCE_GROUP" \
        --gallery-name "$IMAGE_GALLERY" \
        --gallery-image-definition "$IMAGE_NAME" &> /dev/null; then
        
        print_status "Creating image definition: $IMAGE_NAME"
        az sig image-definition create \
            --resource-group "$TARGET_RESOURCE_GROUP" \
            --gallery-name "$IMAGE_GALLERY" \
            --gallery-image-definition "$IMAGE_NAME" \
            --publisher "IstioMesh" \
            --offer "IstioReadyVM" \
            --sku "Ubuntu2204" \
            --location "$LOCATION" \
            --os-type "$OS_TYPE" \
            --os-state "$OS_STATE" \
            --hyper-v-generation "$HYPER_V_GENERATION" \
            --description "Ubuntu 22.04 VM pre-configured for Istio service mesh integration" \
            --features "SecurityType=Standard" \
            --output table
    fi
    
    # Create image version
    print_status "Creating image version: $IMAGE_VERSION"
    az sig image-version create \
        --resource-group "$TARGET_RESOURCE_GROUP" \
        --gallery-name "$IMAGE_GALLERY" \
        --gallery-image-definition "$IMAGE_NAME" \
        --gallery-image-version "$IMAGE_VERSION" \
        --location "$LOCATION" \
        --managed-image "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Compute/virtualMachines/$VM_NAME" \
        --replica-count 1 \
        --target-regions "$LOCATION" \
        --output table
    
    print_status "✓ Managed image created successfully in Compute Gallery"
}

# Cleanup source VM
cleanup_source_vm() {
    if [ "$CLEANUP_VM" = false ]; then
        print_status "Keeping source VM (--cleanup-vm not specified)"
        return
    fi
    
    print_section "Cleaning Up Source VM"
    
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would delete VM: $VM_NAME"
        print_status "[DRY RUN] Would delete associated resources (NICs, disks, public IPs)"
        return
    fi
    
    print_warning "⚠️  About to delete source VM and associated resources!"
    read -p "Are you sure you want to delete the source VM? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Keeping source VM"
        return
    fi
    
    print_status "Deleting VM: $VM_NAME"
    az vm delete \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --yes \
        --force-deletion true
    
    # Delete associated resources
    local nic_name="${VM_NAME}VMNic"
    local disk_name="${VM_NAME}_OsDisk_1"
    local pip_name="${VM_NAME}PublicIP"
    
    print_status "Cleaning up associated resources..."
    
    # Delete NIC
    if az network nic show --resource-group "$RESOURCE_GROUP" --name "$nic_name" &> /dev/null; then
        az network nic delete --resource-group "$RESOURCE_GROUP" --name "$nic_name" --no-wait
        print_status "✓ Network interface deleted: $nic_name"
    fi
    
    # Delete disk
    if az disk show --resource-group "$RESOURCE_GROUP" --name "$disk_name" &> /dev/null; then
        az disk delete --resource-group "$RESOURCE_GROUP" --name "$disk_name" --yes --no-wait
        print_status "✓ OS disk deleted: $disk_name"
    fi
    
    # Delete public IP
    if az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$pip_name" &> /dev/null; then
        az network public-ip delete --resource-group "$RESOURCE_GROUP" --name "$pip_name" --no-wait
        print_status "✓ Public IP deleted: $pip_name"
    fi
    
    print_status "✓ Source VM and associated resources cleaned up"
}

# Display completion summary and usage examples
show_completion_summary() {
    print_section "Image Creation Summary"
    
    if [ "$DRY_RUN" = true ]; then
        print_status "Dry run completed. No resources were modified."
        return
    fi
    
    print_status "✅ VM image creation completed successfully!"
    echo ""
    
    print_status "📋 Created Image:"
    if [ -n "$IMAGE_GALLERY" ]; then
        print_status "  • Compute Gallery: $IMAGE_GALLERY"
        print_status "  • Image Definition: $IMAGE_NAME"
        print_status "  • Image Version: $IMAGE_VERSION"
        print_status "  • Resource Group: $TARGET_RESOURCE_GROUP"
        
        # Get image ID for managed image
        local image_id="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$TARGET_RESOURCE_GROUP/providers/Microsoft.Compute/galleries/$IMAGE_GALLERY/images/$IMAGE_NAME/versions/$IMAGE_VERSION"
        print_status "  • Image ID: $image_id"
    else
        print_status "  • Image Name: $IMAGE_NAME"
        print_status "  • Resource Group: $TARGET_RESOURCE_GROUP"
        print_status "  • Location: $LOCATION"
        
        # Get image ID for standard image
        local image_id="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$TARGET_RESOURCE_GROUP/providers/Microsoft.Compute/images/$IMAGE_NAME"
        print_status "  • Image ID: $image_id"
    fi
    
    echo ""
    print_status "🚀 Deploy VMs from this image:"
    
    if [ -n "$IMAGE_GALLERY" ]; then
        # Managed image deployment examples
        print_status "# Single VM from managed image"
        echo "az vm create \\"
        echo "  --resource-group <target-rg> \\"
        echo "  --name <new-vm-name> \\"
        echo "  --image $image_id \\"
        echo "  --admin-username azureuser \\"
        echo "  --generate-ssh-keys"
        echo ""
        
        print_status "# Multiple VMs with custom data"
        echo "az vm create \\"
        echo "  --resource-group <target-rg> \\"
        echo "  --name <new-vm-name> \\"
        echo "  --image $image_id \\"
        echo "  --admin-username azureuser \\"
        echo "  --generate-ssh-keys \\"
        echo "  --custom-data mesh-config.yaml"
    else
        # Standard image deployment examples
        print_status "# Single VM from standard image"
        echo "az vm create \\"
        echo "  --resource-group <target-rg> \\"
        echo "  --name <new-vm-name> \\"
        echo "  --image $image_id \\"
        echo "  --admin-username azureuser \\"
        echo "  --generate-ssh-keys"
    fi
    
    echo ""
    print_status "📚 Useful Commands:"
    if [ -n "$IMAGE_GALLERY" ]; then
        print_status "  View image: az sig image-version show -g $TARGET_RESOURCE_GROUP --gallery-name $IMAGE_GALLERY --gallery-image-definition $IMAGE_NAME --gallery-image-version $IMAGE_VERSION"
        print_status "  List versions: az sig image-version list -g $TARGET_RESOURCE_GROUP --gallery-name $IMAGE_GALLERY --gallery-image-definition $IMAGE_NAME"
    else
        print_status "  View image: az image show -g $TARGET_RESOURCE_GROUP -n $IMAGE_NAME"
        print_status "  List images: az image list -g $TARGET_RESOURCE_GROUP --output table"
    fi
    
    echo ""
    print_status "🔧 Post-deployment steps for new VMs:"
    print_status "1. Transfer mesh certificates and configuration files"
    print_status "2. Run: ./complete-mesh-setup.sh"
    print_status "3. Verify: ./check-service.sh"
    print_status "4. Create WorkloadEntry in Kubernetes cluster"
}

# Main execution
main() {
    print_section "Azure VM Image Creation for Istio-Ready VMs"
    
    validate_prerequisites
    show_configuration
    check_vm_readiness
    prepare_vm
    deallocate_vm
    create_vm_image
    cleanup_source_vm
    show_completion_summary
    
    print_status "🎉 Image creation workflow completed!"
}

# Execute main function
main "$@"