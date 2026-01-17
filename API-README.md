# Istio VM Manager Service

A comprehensive Go microservice that automates the creation, configuration, and mesh integration of Azure Virtual Machines with Istio service mesh. This service provides APIs to create VMs with cloud-init, handle post-boot tasks, and seamlessly integrate VMs into an Istio mesh.

## Features

- **VM Lifecycle Management**: Create, configure, and delete Azure VMs
- **Istio Mesh Integration**: Automatic WorkloadEntry and ServiceEntry creation
- **Cloud-Init Automation**: Automated VM provisioning with cloud-init
- **Post-Boot Task Execution**: Configurable tasks after VM startup
- **Certificate Management**: Automatic Istio certificate and token generation
- **RESTful API**: Comprehensive HTTP API for all operations
- **Docker Support**: Containerized deployment with all required tools

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Docker        │    │   Go            │    │   Azure         │
│   Container     │────│   Microservice  │────│   Resources     │
│                 │    │                 │    │                 │
│ • Azure CLI     │    │ • VM Service    │    │ • VMs           │
│ • kubectl       │    │ • Istio Service │    │ • Networking    │
│ • istioctl      │    │ • K8s Service   │    │ • Security      │
│ • Terraform     │    │ • API Layer     │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
        │                       │                       │
        └───────────────────────┼───────────────────────┘
                                │
                     ┌─────────────────┐
                     │   Kubernetes    │
                     │   + Istio       │
                     │                 │
                     │ • WorkloadEntry │
                     │ • ServiceEntry  │
                     │ • Certificates  │
                     │ • Mesh Config   │
                     └─────────────────┘
```

## Prerequisites

- Azure subscription with appropriate permissions
- Kubernetes cluster with Istio installed
- Docker and Docker Compose
- kubectl configured for your cluster
- Azure CLI authenticated

## Quick Start

### 1. Environment Setup

Create a `.env` file with your Azure credentials:

```bash
# Azure Configuration
AZURE_SUBSCRIPTION_ID=your-subscription-id
AZURE_TENANT_ID=your-tenant-id
AZURE_CLIENT_ID=your-client-id
AZURE_CLIENT_SECRET=your-client-secret

# Optional: Custom configuration
LOG_LEVEL=info
ENVIRONMENT=development
```

### 2. Build and Run

```bash
# Build the Docker image
docker-compose build

# Start the service
docker-compose up -d

# Check service health
curl http://localhost:8080/health
```

### 3. Verify Installation

```bash
# Get service version
curl http://localhost:8080/version

# Check cluster connectivity
curl http://localhost:8080/api/v1/cluster/info
```

## API Documentation

### VM Management

#### Create a Basic VM

```bash
curl -X POST http://localhost:8080/api/v1/vms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-test-vm",
    "size": "Standard_B2s",
    "ssh_public_key": "ssh-rsa AAAAB3NzaC1yc2E...",
    "tags": {
      "environment": "test",
      "project": "istio-mesh"
    }
  }'
```

#### Deploy VM with Full Mesh Integration

```bash
curl -X POST http://localhost:8080/api/v1/vms/deploy \
  -H "Content-Type: application/json" \
  -d '{
    "name": "istio-vm-1",
    "size": "Standard_B2s",
    "ssh_public_key": "ssh-rsa AAAAB3NzaC1yc2E...",
    "service_name": "my-vm-service",
    "mesh_integration": {
      "enabled": true,
      "namespace": "istio-system",
      "create_workload_entry": true,
      "create_service_entry": true,
      "labels": {
        "app": "my-vm-service",
        "version": "v1"
      }
    },
    "post_boot_tasks": [
      {
        "name": "wait_for_boot",
        "type": "wait",
        "parameters": {
          "duration": "2m"
        }
      },
      {
        "name": "validate_service",
        "type": "validate",
        "parameters": {
          "endpoint": "http://localhost:8080/health"
        }
      }
    ],
    "auto_cleanup": false,
    "timeout_minutes": 30
  }'
```

#### Get VM Information

```bash
# List all VMs
curl http://localhost:8080/api/v1/vms

# Get specific VM
curl http://localhost:8080/api/v1/vms/my-test-vm

# Get deployment status
curl http://localhost:8080/api/v1/vms/my-test-vm/status
```

#### Delete VM

```bash
# Delete VM only
curl -X DELETE http://localhost:8080/api/v1/vms/my-test-vm

# Cleanup all resources (VM + Istio resources)
curl -X DELETE http://localhost:8080/api/v1/vms/my-test-vm/cleanup
```

### Istio Mesh Operations

#### Get Mesh Status

```bash
curl http://localhost:8080/api/v1/mesh/status
```

#### Create WorkloadEntry Manually

```bash
curl -X POST http://localhost:8080/api/v1/mesh/workload-entries \
  -H "Content-Type: application/json" \
  -d '{
    "name": "manual-workload",
    "namespace": "default",
    "address": "10.0.1.100",
    "network": "vm-network",
    "labels": {
      "app": "manual-service",
      "version": "v1"
    },
    "ports": {
      "http": 8080
    }
  }'
```

#### Generate VM Mesh Files

```bash
# Generate certificates and configuration files for VM
curl "http://localhost:8080/api/v1/mesh/vm/my-vm/files?ip=10.0.1.100&namespace=istio-system"
```

#### Validate VM Connection

```bash
curl "http://localhost:8080/api/v1/mesh/validate?ip=10.0.1.100"
```

### Cluster Information

#### Get Cluster Info

```bash
curl http://localhost:8080/api/v1/cluster/info
```

#### List Namespaces

```bash
curl http://localhost:8080/api/v1/cluster/namespaces
```

## Configuration

### Main Configuration File

The service uses `/app/configs/config.yaml`:

```yaml
environment: "development"
log_level: "info"

azure:
  subscription_id: "${AZURE_SUBSCRIPTION_ID}"
  tenant_id: "${AZURE_TENANT_ID}"
  client_id: "${AZURE_CLIENT_ID}"
  client_secret: "${AZURE_CLIENT_SECRET}"
  location: "East US"
  resource_group_name: "istio-vm-mesh-rg"

kubernetes:
  config_path: "${KUBECONFIG}"
  context: ""
  namespace: "istio-system"

istio:
  mesh_id: "cluster.local"
  network: "vm-network"
  cluster_name: "Kubernetes"
  namespace: "istio-system"

vm:
  default_size: "Standard_B2s"
  default_image:
    publisher: "Canonical"
    offer: "0001-com-ubuntu-server-focal"
    sku: "20_04-lts-gen2"
    version: "latest"
  default_networking:
    vnet_name: "istio-vm-vnet"
    subnet_name: "vm-subnet"
    security_group_name: "istio-vm-nsg"
    public_ip_enabled: true
  cloud_init_template_path: "/app/templates/cloud-init-istio-vm.yaml"
  tags:
    project: "istio-vm-mesh"
    environment: "development"
    managed_by: "vm-manager"
```

### Cloud-Init Template

The service includes a comprehensive cloud-init template that:

- Installs Docker and container runtime
- Downloads and installs Istio tools
- Configures VM for mesh integration
- Sets up networking and security
- Prepares the VM for Istio sidecar injection

## Post-Boot Tasks

The service supports various post-boot task types:

### Wait Task

```json
{
  "name": "wait_for_boot",
  "type": "wait",
  "parameters": {
    "duration": "2m"
  }
}
```

### Validation Task

```json
{
  "name": "validate_service",
  "type": "validate",
  "timeout_seconds": 300,
  "parameters": {
    "endpoint": "http://localhost:8080/health"
  }
}
```

### Script Execution Task

```json
{
  "name": "install_app",
  "type": "script",
  "command": "bash /tmp/install-app.sh",
  "timeout_seconds": 600,
  "retry_count": 3
}
```

## Deployment Scenarios

### Development Environment

```bash
# Start with development profile
docker-compose --profile development up -d
```

### Production Environment

```bash
# Start with production profile (includes nginx proxy)
docker-compose --profile production up -d
```

### Custom Configuration

```bash
# Use custom config file
docker run -d \
  -p 8080:8080 \
  -v $(pwd)/my-config.yaml:/app/configs/config.yaml \
  -v ~/.kube/config:/app/kubeconfig:ro \
  istio-vm-manager:latest
```

## Monitoring and Logging

### Health Checks

The service provides comprehensive health checks:

```bash
# Basic health
curl http://localhost:8080/health

# Service statistics
curl http://localhost:8080/stats

# Version information
curl http://localhost:8080/version
```

### Logs

```bash
# View service logs
docker-compose logs -f vm-manager

# View specific container logs
docker logs istio-vm-manager
```

## Security Considerations

1. **Azure Credentials**: Use Azure Managed Identity when possible
2. **Kubernetes Access**: Limit service account permissions
3. **Network Security**: Configure appropriate security groups
4. **TLS/SSL**: Use HTTPS in production (nginx proxy included)
5. **Secret Management**: Use Azure Key Vault for sensitive data

## Troubleshooting

### Common Issues

1. **Azure Authentication Failed**
   ```bash
   # Verify Azure credentials
   docker exec -it istio-vm-manager az account show
   ```

2. **Kubernetes Connection Failed**
   ```bash
   # Check kubeconfig
   docker exec -it istio-vm-manager kubectl cluster-info
   ```

3. **Istio Not Found**
   ```bash
   # Verify Istio installation
   docker exec -it istio-vm-manager istioctl version
   ```

4. **VM Creation Failed**
   ```bash
   # Check Azure permissions and quotas
   curl http://localhost:8080/api/v1/vms/failed-vm/status
   ```

### Debug Mode

```bash
# Enable debug logging
docker-compose up -d -e LOG_LEVEL=debug
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Submit a pull request

## License

This project is licensed under the MIT License.

## Support

For issues and questions:
- Create an issue in the repository
- Check the troubleshooting section
- Review the API documentation