# Salt Configuration for Istio VM Mesh Integration

This directory contains Salt state files for setting up Azure VMs as part of an Istio service mesh, replacing the previous CloudInit configuration with a more robust, two-stage Salt approach.

## Overview

The Salt configuration is split into two main execution phases:

1. **Image Build Phase** (`image-build.sls`): Executed once during VM image creation
2. **Boot-Time Phase** (`boot-time.sls`): Executed every time a VM boots from the prepared image

This separation provides better control over when different configurations are applied and allows for more efficient VM scaling and management.

## File Structure

```text
salt/
├── README.md           # This file
├── image-build.sls     # Image build Salt state (execute once)
├── boot-time.sls       # Boot-time Salt state (execute at every boot)
├── top.sls            # Salt state tree configuration
├── pillar.sls         # Configuration data and variables
└── minion.conf        # Salt minion configuration for VMs
```

## Quick Start

### 1. Prepare VM Image

```bash
# Install Salt on your base VM image
curl -o bootstrap_salt.sh -L https://bootstrap.saltstack.com
sudo sh bootstrap_salt.sh -M  # Masterless setup

# Copy Salt files to the VM
sudo mkdir -p /srv/salt /srv/pillar /etc/salt
sudo cp *.sls /srv/salt/
sudo cp pillar.sls /srv/pillar/
sudo cp minion.conf /etc/salt/minion

# Execute image build configuration
sudo salt-call --local state.apply image-build

# Create VM image snapshot (Azure example)
az vm deallocate --resource-group myRG --name myVM
az vm generalize --resource-group myRG --name myVM
az image create --resource-group myRG --name myImage --source myVM
```

### 2. Deploy VMs from Image

```bash
# Create VM from prepared image
az vm create \
  --resource-group myRG \
  --name istio-vm-1 \
  --image myImage \
  --admin-username azureuser \
  --generate-ssh-keys

# Transfer certificates (from cluster setup)
VM_IP=$(az vm show -d -g myRG -n istio-vm-1 --query publicIps -o tsv)
ssh azureuser@$VM_IP 'mkdir -p /tmp/vm-files'
scp -r ../workspace/vm-mesh-setup/vm-files/* azureuser@$VM_IP:/tmp/vm-files/

# Boot-time configuration will run automatically
# Or trigger manually: ssh azureuser@$VM_IP 'sudo salt-call --local state.apply boot-time'
```

## Configuration Files

### image-build.sls

**Purpose**: One-time setup during VM image creation

**Key Actions**:

- Install required packages (curl, iptables, wget, systemd, unzip, ufw)
- Create Istio directory structure
- Deploy health check and setup scripts
- Install Istio sidecar components
- Configure firewall rules
- Set up system services

**Execution**: Manual during image build process

### boot-time.sls

**Purpose**: Runtime configuration executed at every VM boot

**Key Actions**:

- Verify directory permissions
- Detect and install certificates from `/tmp/vm-files/`
- Automatically configure Istio mesh integration
- Perform health checks
- Start/restart Istio services
- Log boot process

**Execution**: Automatic via Salt minion startup states

### top.sls

**Purpose**: Define which states apply to which minions

**Configuration**:

- `base` state: Applies `image-build` to all minions
- Role-based targeting: Applies `boot-time` to VMs with `role:istio-vm` grain
- Hostname targeting: Applies `boot-time` to VMs with `istio-vm*` names

### pillar.sls

**Purpose**: Configuration data and variables

**Contains**:

- Istio version and download URLs
- Directory paths
- Port configurations
- Azure VM settings
- Firewall rules
- Health check parameters
- Environment-specific settings

### minion.conf

**Purpose**: Salt minion configuration for masterless operation

**Key Settings**:

- Masterless mode enabled (`file_client: local`)
- Automatic startup states (`startup_states: sls`)
- Boot-time state execution (`sls_list: [boot-time]`)
- System grains for targeting
- Logging configuration

## Usage Patterns

### Single VM Deployment

```bash
# 1. Create VM from prepared image
az vm create --resource-group myRG --name istio-vm --image myIstioImage

# 2. Transfer certificates
VM_IP=$(az vm show -d -g myRG -n istio-vm --query publicIps -o tsv)
scp -r vm-files/* azureuser@$VM_IP:/tmp/vm-files/

# 3. Verify setup (boot-time state runs automatically)
ssh azureuser@$VM_IP './check-service.sh'
```

### Multiple VM Deployment

```bash
# Create multiple VMs
for i in {1..3}; do
  az vm create \
    --resource-group myRG \
    --name istio-vm-$i \
    --image myIstioImage \
    --no-wait
done

# Transfer certificates to all VMs
VMS=($(az vm list -g myRG --query "[?starts_with(name, 'istio-vm-')].name" -o tsv))
for vm in "${VMS[@]}"; do
  VM_IP=$(az vm show -d -g myRG -n $vm --query publicIps -o tsv)
  scp -r vm-files/* azureuser@$VM_IP:/tmp/vm-files/
done
```

### Manual State Execution

```bash
# Run specific states manually
sudo salt-call --local state.apply image-build    # Image build state
sudo salt-call --local state.apply boot-time      # Boot-time state

# Test states without applying changes
sudo salt-call --local state.apply boot-time test=True

# Show what would be executed
sudo salt-call --local state.show_sls boot-time
```

## Monitoring and Troubleshooting

### Log Files

```bash
# Salt execution logs
sudo tail -f /var/log/salt/minion

# Istio boot process logs
sudo tail -f /var/log/istio-boot.log

# System service logs
sudo journalctl -u salt-minion -f
sudo journalctl -u istio -f
```

### Health Checks

```bash
# VM-level health check
./check-service.sh

# Detailed service status
./service-status.sh

# Salt state status
sudo salt-call --local state.show_highstate
```

### Common Operations

```bash
# Restart Salt minion
sudo systemctl restart salt-minion

# Force re-run boot-time configuration
sudo salt-call --local state.apply boot-time

# Check Salt grains
sudo salt-call --local grains.items

# Validate Salt configuration
sudo salt-call --local state.show_sls boot-time
```

## Customization

### Environment-Specific Configuration

Edit `pillar.sls` to customize for different environments:

```yaml
environments:
  production:
    log_level: INFO
    health_check_interval: 60
  development:
    log_level: DEBUG
    health_check_interval: 15
```

### Adding Custom States

1. Create new `.sls` files in the Salt directory
2. Update `top.sls` to include the new states
3. Add configuration variables to `pillar.sls` if needed

### Modifying Istio Version

Update `pillar.sls`:

```yaml
istio:
  version: "1.28.0"  # Change version here
```

## Integration with Azure

### ARM Templates

Include Salt configuration in ARM templates:

```json
{
  "type": "Microsoft.Compute/virtualMachines/extensions",
  "name": "[concat(variables('vmName'), '/CustomScript')]",
  "properties": {
    "publisher": "Microsoft.Azure.Extensions",
    "type": "CustomScript",
    "settings": {
      "script": "c3VkbyBzYWx0LWNhbGwgLS1sb2NhbCBzdGF0ZS5hcHBseSBib290LXRpbWU="
    }
  }
}
```

### Azure Automation

Use Azure Automation runbooks to manage Salt states across multiple VMs.

### VMSS Integration

For Virtual Machine Scale Sets, include Salt configuration in the scale set template.

## Best Practices

1. **Version Control**: Keep Salt states in version control
2. **Testing**: Test states in development before production
3. **Idempotency**: Ensure states can be run multiple times safely
4. **Logging**: Monitor Salt execution logs regularly
5. **Security**: Secure certificate transfer process
6. **Backup**: Backup VM images with working configurations
7. **Documentation**: Document any custom modifications

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Salt minion not starting | Configuration error | Check `/etc/salt/minion` syntax |
| States failing | Missing dependencies | Verify package installation |
| Istio not starting | Missing certificates | Check `/tmp/vm-files/` contents |
| Network connectivity | Firewall rules | Verify UFW configuration |

### Debug Mode

Run Salt in debug mode for detailed troubleshooting:

```bash
sudo salt-call --local state.apply boot-time -l debug
```

## Migration from CloudInit

If migrating from CloudInit:

1. **Backup existing configuration**
2. **Test Salt states in development**
3. **Create new VM images with Salt**
4. **Update deployment scripts**
5. **Monitor first deployments closely**

## Support

For issues related to:

- **Salt configuration**: Check Salt documentation and logs
- **Istio integration**: Verify cluster-side configuration
- **Azure integration**: Check Azure resource configurations
- **Network connectivity**: Verify security groups and firewall rules
