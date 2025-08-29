# Azure AKS + Istio Service Mesh Setup

This repository provides a comprehensive, automated setup for deploying Istio service mesh on Azure Kubernetes Service (AKS) with VM mesh integration and sample applications.

## 🚀 Features

- **Automated AKS + Istio Setup**: Complete setup with Azure-optimized configurations
- **HelloWorld Sample**: Deployed automatically during setup with traffic distribution
- **VM Mesh Integration**: Connect external VMs to the service mesh
- **Sample Applications**: Bookinfo, HTTPBin, and other Istio samples
- **Observability Tools**: Kiali, Grafana, and Jaeger with gateway access
- **Local Workspace**: Organized structure with samples and configurations
- **Azure Best Practices**: Optimized for Azure AKS with proper security and performance settings

## 📋 Prerequisites

Before running the setup, ensure you have:

- **Azure CLI** installed and configured (`az login`)
- **kubectl** installed
- **OpenSSL** for certificate generation
- **curl** for connectivity testing
- **SSH key** configured for Azure VMs (generated automatically if not present)
- **Azure subscription** with contributor permissions

### Installation Commands

```bash
# Install Azure CLI (macOS)
brew install azure-cli

# Install kubectl
az aks install-cli

# Login to Azure
az login
```

## 🏗️ Quick Start

### 1. Clone and Setup

```bash
git clone https://github.com/johandry/IstioAzureSetup.git
cd azure-setup
```

### 2. Complete Setup (Recommended)

```bash
./setup-istio.sh setup
```

This command will:

- Create Azure Resource Group, AKS cluster, and VM
- Install and configure Istio with Azure optimizations
- Deploy HelloWorld sample application
- Set up observability tools (Kiali, Grafana, Jaeger)
- Create local workspace with Istio samples

### 3. Test the HelloWorld Application

```bash
# Get the external IP (may take a few minutes to assign)
GATEWAY_IP=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Test HelloWorld
curl http://$GATEWAY_IP/hello

# Test load balancing between v1 and v2
for i in {1..10}; do curl http://$GATEWAY_IP/hello; echo; done
```

## 🎯 Available Commands

```bash
./setup-istio.sh [COMMAND] [OPTIONS]
```

### Commands

- `setup` - Complete AKS and Istio setup with HelloWorld (default)
- `deploy-samples` - Deploy additional Istio sample applications
- `setup-vm-mesh` - Setup VM mesh integration
- `deploy-mesh-test` - Deploy mesh testing applications
- `test-mesh` - Test VM mesh integration
- `status` - Show current deployment status
- `port-forward [stop]` Forward ports for services and dashboards
- `cleanup` - Clean up all Azure resources
- `cleanup local` - Clean up local workspace only
- `help` - Show usage information

### Options

- `--resource-group NAME` - Override resource group name
- `--cluster-name NAME` - Override cluster name
- `--vm-name NAME` - Override VM name
- `--location LOCATION` - Override Azure location

## 🌐 Access Your Applications

After successful setup, you'll have access to:

### HelloWorld Sample Application

- **URL**: `http://<GATEWAY-IP>/hello`
- **Description**: Simple application demonstrating traffic distribution between v1 and v2
- **Testing**: Refresh multiple times to see load balancing

### Observability Tools

- **Kiali Dashboard**: `http://<GATEWAY-IP>/kiali` - Service mesh topology
- **Grafana Dashboard**: `http://<GATEWAY-IP>/grafana` - Metrics and monitoring
- **Jaeger Tracing**: `http://<GATEWAY-IP>/jaeger` - Distributed tracing

### Additional Samples (Optional)

```bash
./setup-istio.sh deploy-samples
```

- **Bookinfo**: `http://<GATEWAY-IP>/productpage`
- **HTTPBin**: `http://<GATEWAY-IP>/httpbin/headers`

## 🗂️ Workspace Structure

The setup creates an organized local workspace:

```tree
IstioAzureSetup/
├── setup-istio.sh                 # Main setup script
├── scripts/                       # Additional deployment scripts
└── workspace/                     # Local workspace (created during setup)
    ├── istio-installation/         # Istio binaries and samples
    │   ├── bin/istioctl           # Istio CLI tool
    │   ├── samples/               # All Istio sample applications
    │   └── manifests/             # Installation manifests
    ├── vm-mesh-setup/             # VM mesh integration files
    ├── certs/                     # TLS certificates
    └── configs/                   # Configuration files
        ├── vm-config.env          # VM connection details
        └── azure-config.env       # Azure LoadBalancer details
```

## ⚙️ Azure Configuration Details

### AKS Cluster Configuration

- **Node Count**: 3 nodes
- **VM Size**: Standard_L8s_v3 (optimized for networking)
- **Network Plugin**: Azure CNI
- **Monitoring**: Enabled with Azure Monitor

### Security Features

- **Managed Identity**: Enabled for secure Azure integration
- **TLS Certificates**: Auto-generated for HTTPS endpoints
- **Network Security**: Proper port configurations for Istio traffic

## 🔧 Troubleshooting

### Common Issues

#### 1. Gateway IP Not Assigned

```bash
# Check LoadBalancer status
kubectl get svc istio-ingressgateway -n istio-system -w

# Check Azure LoadBalancer events
kubectl describe svc istio-ingressgateway -n istio-system
```

#### 2. HelloWorld Not Responding

```bash
# Check pod status
kubectl get pods -l app=helloworld

# Check service configuration
kubectl get svc helloworld
kubectl get virtualservice helloworld

# Test internal connectivity
kubectl exec -it deployment/sleep -- curl helloworld:5000/hello
```

#### 3. Istio Installation Issues

```bash
# Check Istio system pods
kubectl get pods -n istio-system

# Verify Istio configuration
istioctl analyze

# Check Istio proxy configuration
istioctl proxy-config cluster deployment/helloworld-v1
```

### Debug Commands

```bash
# Check all resources
./setup-istio.sh status

# Test connectivity from within cluster
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- sh
curl helloworld.default.svc.cluster.local:5000/hello

# View Istio configuration
export PATH="workspace/istio-installation/bin:$PATH"
istioctl version
istioctl proxy-status
```

## 🧹 Cleanup

### Clean Up Azure Resources

```bash
./setup-istio.sh cleanup
# This deletes the entire resource group and all resources
```

### Clean Up Local Workspace Only

```bash
./setup-istio.sh cleanup local
# This removes only the local workspace directory
```
