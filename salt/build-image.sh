#!/bin/bash
# Script to build VM image with Salt configuration

set -e

RESOURCE_GROUP="${1:-istio-playground-rg}"
BASE_VM_NAME="${2:-istio-base-vm}"
IMAGE_NAME="${3:-istio-vm-image}"
LOCATION="${4:-westus2}"

print_status() {
    echo -e "\033[0;32m[INFO]\033[0m $1"
}

print_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1"
}

print_status "Building Istio VM Image with Salt Configuration"
print_status "Resource Group: $RESOURCE_GROUP"
print_status "Base VM: $BASE_VM_NAME"
print_status "Image Name: $IMAGE_NAME"

# Create base VM if it doesn't exist
if ! az vm show --resource-group $RESOURCE_GROUP --name $BASE_VM_NAME >/dev/null 2>&1; then
    print_status "Creating base VM: $BASE_VM_NAME"
    az vm create \
        --resource-group $RESOURCE_GROUP \
        --name $BASE_VM_NAME \
        --image Ubuntu2004 \
        --admin-username azureuser \
        --generate-ssh-keys \
        --size Standard_B2s \
        --location $LOCATION
else
    print_status "Base VM $BASE_VM_NAME already exists"
fi

# Get VM IP
VM_IP=$(az vm show -d --resource-group $RESOURCE_GROUP --name $BASE_VM_NAME --query publicIps -o tsv)
print_status "VM IP: $VM_IP"

# Wait for VM to be ready
print_status "Waiting for VM to be ready..."
for i in {1..30}; do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no azureuser@$VM_IP 'echo "VM Ready"' >/dev/null 2>&1; then
        print_status "VM is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        print_error "VM failed to become ready after 5 minutes"
        exit 1
    fi
    sleep 10
done

# Install Salt on the VM
print_status "Installing Salt on VM..."
ssh azureuser@$VM_IP 'curl -o bootstrap_salt.sh -L https://bootstrap.saltstack.com && sudo sh bootstrap_salt.sh -M'

# Copy Salt configuration files
print_status "Copying Salt configuration files..."
ssh azureuser@$VM_IP 'sudo mkdir -p /srv/salt /srv/pillar /etc/salt'

# Copy all .sls files
scp -o StrictHostKeyChecking=no *.sls azureuser@$VM_IP:~/
ssh azureuser@$VM_IP 'sudo cp *.sls /srv/salt/ && sudo cp pillar.sls /srv/pillar/top.sls'

# Copy minion configuration
scp -o StrictHostKeyChecking=no minion.conf azureuser@$VM_IP:~/
ssh azureuser@$VM_IP 'sudo cp minion.conf /etc/salt/minion'

# Execute image build Salt state
print_status "Executing Salt image build configuration..."
ssh azureuser@$VM_IP 'sudo salt-call --local state.apply image-build'

# Verify installation
print_status "Verifying installation..."
ssh azureuser@$VM_IP 'test -f /etc/istio-image-build-complete && echo "✓ Image build completed" || echo "✗ Image build incomplete"'

# Clean up VM for imaging
print_status "Preparing VM for imaging..."
ssh azureuser@$VM_IP '
    sudo apt-get clean
    sudo rm -rf /tmp/*
    sudo rm -rf /var/tmp/*
    sudo rm -rf /home/azureuser/.ssh/authorized_keys
    history -c
    sudo waagent -deprovision+user -force
'

print_status "Deallocating VM..."
az vm deallocate --resource-group $RESOURCE_GROUP --name $BASE_VM_NAME

print_status "Generalizing VM..."
az vm generalize --resource-group $RESOURCE_GROUP --name $BASE_VM_NAME

print_status "Creating VM image..."
az image create \
    --resource-group $RESOURCE_GROUP \
    --name $IMAGE_NAME \
    --source $BASE_VM_NAME \
    --location $LOCATION

print_status "✅ VM Image created successfully: $IMAGE_NAME"
print_status "You can now use this image to create Istio-ready VMs"

# Optionally delete the base VM
read -p "Delete base VM $BASE_VM_NAME? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_status "Deleting base VM..."
    az vm delete --resource-group $RESOURCE_GROUP --name $BASE_VM_NAME --yes
    print_status "Base VM deleted"
fi

print_status "Image build process completed!"