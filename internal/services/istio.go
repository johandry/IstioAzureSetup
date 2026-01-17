package services
package services

import (
	"context"
	"encoding/base64"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/johandry/IstioAzureSetup/internal/config"
	"github.com/sirupsen/logrus"
)

// IstioService handles Istio-specific operations
type IstioService struct {
	config     config.IstioConfig
	kubeClient *KubernetesService
}

// MeshConfig represents Istio mesh configuration
type MeshConfig struct {
	MeshID        string `json:"mesh_id"`
	Network       string `json:"network"`
	ClusterName   string `json:"cluster_name"`
	TrustDomain   string `json:"trust_domain"`
	RootCert      string `json:"root_cert"`
	CertChain     string `json:"cert_chain"`
	PrivateKey    string `json:"private_key"`
	IstiodAddress string `json:"istiod_address"`
}

// VMMeshFiles represents the files needed for VM mesh integration
type VMMeshFiles struct {
	ClusterEnv     string `json:"cluster_env"`
	MeshYAML       string `json:"mesh_yaml"`
	RootCertPEM    string `json:"root_cert_pem"`
	CertChainPEM   string `json:"cert_chain_pem"`
	PrivateKeyPEM  string `json:"private_key_pem"`
	IstioToken     string `json:"istio_token"`
	Hosts          string `json:"hosts"`
}

// NewIstioService creates a new Istio service instance
func NewIstioService(kubeClient *KubernetesService, config config.IstioConfig) (*IstioService, error) {
	return &IstioService{
		config:     config,
		kubeClient: kubeClient,
	}, nil
}

// GenerateVMFiles generates all necessary files for VM mesh integration
func (i *IstioService) GenerateVMFiles(ctx context.Context, vmName, vmIP, namespace string) (*VMMeshFiles, error) {
	logrus.Infof("Generating VM mesh files for VM: %s (IP: %s)", vmName, vmIP)

	if namespace == "" {
		namespace = i.config.Namespace
	}

	// Generate Istio token
	token, err := i.generateIstioToken(ctx, vmName, namespace)
	if err != nil {
		return nil, fmt.Errorf("failed to generate Istio token: %w", err)
	}

	// Get root certificate
	rootCert, err := i.getRootCertificate(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get root certificate: %w", err)
	}

	// Get Istiod address
	istiodAddress, err := i.getIstiodAddress(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get Istiod address: %w", err)
	}

	// Generate cluster.env file
	clusterEnv := fmt.Sprintf(`ISTIO_SERVICE_CIDR=10.0.0.0/16
ISTIO_INBOUND_PORTS=*
ISTIO_LOCAL_GATEWAY_PORT=15008
ISTIO_PILOT_PORT=15010
ISTIO_CP_ADDRESS=%s
`, istiodAddress)

	// Generate mesh.yaml file
	meshYAML := fmt.Sprintf(`apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-vm-%s
spec:
  meshConfig:
    defaultConfig:
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
        ISTIO_META_DNS_AUTO_ALLOCATE: "true"
        ISTIO_META_NETWORK: %s
        ISTIO_META_CLUSTER_ID: %s
`, vmName, i.config.Network, i.config.ClusterName)

	// Generate hosts file entries
	hosts := fmt.Sprintf(`%s istiod.istio-system.svc`, istiodAddress)

	files := &VMMeshFiles{
		ClusterEnv:    clusterEnv,
		MeshYAML:      meshYAML,
		RootCertPEM:   rootCert,
		IstioToken:    token,
		Hosts:         hosts,
	}

	return files, nil
}

// CreateWorkloadEntryForVM creates a WorkloadEntry for a VM
func (i *IstioService) CreateWorkloadEntryForVM(ctx context.Context, vmName, vmIP, namespace string, labels map[string]string) error {
	logrus.Infof("Creating WorkloadEntry for VM: %s", vmName)

	if namespace == "" {
		namespace = i.config.Namespace
	}

	// Add default labels
	if labels == nil {
		labels = make(map[string]string)
	}
	labels["app"] = vmName
	labels["version"] = "v1"

	entry := &WorkloadEntry{
		Name:      fmt.Sprintf("vm-%s", vmName),
		Namespace: namespace,
		Address:   vmIP,
		Network:   i.config.Network,
		Labels:    labels,
		Ports: map[string]uint32{
			"http": 8080,
		},
	}

	return i.kubeClient.CreateWorkloadEntry(ctx, entry)
}

// CreateServiceEntryForVM creates a ServiceEntry for a VM service
func (i *IstioService) CreateServiceEntryForVM(ctx context.Context, vmName, vmIP, serviceName, namespace string) error {
	logrus.Infof("Creating ServiceEntry for VM service: %s", serviceName)

	if namespace == "" {
		namespace = i.config.Namespace
	}

	entry := &ServiceEntry{
		Name:      fmt.Sprintf("vm-%s-service", vmName),
		Namespace: namespace,
		Hosts:     []string{serviceName},
		Location:  "MESH_EXTERNAL",
		Ports: []ServicePort{
			{
				Number:   8080,
				Name:     "http",
				Protocol: "HTTP",
			},
		},
		Endpoints: []WorkloadEndpoint{
			{
				Address: vmIP,
				Network: i.config.Network,
				Ports: map[string]uint32{
					"http": 8080,
				},
			},
		},
	}

	return i.kubeClient.CreateServiceEntry(ctx, entry)
}

// CleanupVMResources removes all Istio resources associated with a VM
func (i *IstioService) CleanupVMResources(ctx context.Context, vmName, namespace string) error {
	logrus.Infof("Cleaning up Istio resources for VM: %s", vmName)

	if namespace == "" {
		namespace = i.config.Namespace
	}

	// Delete WorkloadEntry
	workloadEntryName := fmt.Sprintf("vm-%s", vmName)
	if err := i.kubeClient.DeleteWorkloadEntry(ctx, workloadEntryName, namespace); err != nil {
		logrus.Warnf("Failed to delete WorkloadEntry %s: %v", workloadEntryName, err)
	}

	// Delete ServiceEntry
	serviceEntryName := fmt.Sprintf("vm-%s-service", vmName)
	if err := i.kubeClient.DeleteServiceEntry(ctx, serviceEntryName, namespace); err != nil {
		logrus.Warnf("Failed to delete ServiceEntry %s: %v", serviceEntryName, err)
	}

	return nil
}

// GetMeshStatus retrieves the current status of the Istio mesh
func (i *IstioService) GetMeshStatus(ctx context.Context) (map[string]interface{}, error) {
	// Use istioctl to get proxy status
	cmd := exec.CommandContext(ctx, "istioctl", "proxy-status")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("failed to get proxy status: %w, output: %s", err, string(output))
	}

	// Use istioctl to get proxy config
	cmd = exec.CommandContext(ctx, "istioctl", "version")
	versionOutput, err := cmd.CombinedOutput()
	if err != nil {
		logrus.Warnf("Failed to get Istio version: %v", err)
	}

	status := map[string]interface{}{
		"proxy_status": string(output),
		"version":      string(versionOutput),
		"mesh_id":      i.config.MeshID,
		"network":      i.config.Network,
		"cluster_name": i.config.ClusterName,
		"timestamp":    time.Now().UTC().Format(time.RFC3339),
	}

	return status, nil
}

// ValidateVMConnection tests the connection between a VM and the mesh
func (i *IstioService) ValidateVMConnection(ctx context.Context, vmIP string) (bool, error) {
	logrus.Infof("Validating VM connection for IP: %s", vmIP)

	// This is a simplified validation - in production, you might want to:
	// 1. Check if the VM proxy is connected to Istiod
	// 2. Verify certificate exchange
	// 3. Test service discovery
	
	// For now, we'll just try to ping the VM
	cmd := exec.CommandContext(ctx, "ping", "-c", "3", vmIP)
	if err := cmd.Run(); err != nil {
		return false, fmt.Errorf("VM unreachable: %w", err)
	}

	return true, nil
}

// Helper methods

func (i *IstioService) generateIstioToken(ctx context.Context, vmName, namespace string) (string, error) {
	// Create a ServiceAccount for the VM workload
	saName := fmt.Sprintf("vm-%s", vmName)
	
	// Use kubectl to create ServiceAccount and get token
	cmd := exec.CommandContext(ctx, "kubectl", "create", "serviceaccount", saName, "-n", namespace)
	output, err := cmd.CombinedOutput()
	if err != nil && !strings.Contains(string(output), "already exists") {
		return "", fmt.Errorf("failed to create service account: %w, output: %s", err, string(output))
	}

	// Get the token
	cmd = exec.CommandContext(ctx, "kubectl", "create", "token", saName, "-n", namespace, "--duration=8760h")
	tokenBytes, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("failed to create token: %w, output: %s", err, string(tokenBytes))
	}

	return strings.TrimSpace(string(tokenBytes)), nil
}

func (i *IstioService) getRootCertificate(ctx context.Context) (string, error) {
	// Get the root certificate from the Istio system
	cmd := exec.CommandContext(ctx, "kubectl", "get", "secret", "cacerts", 
		"-n", i.config.Namespace, "-o", "jsonpath='{.data.root-cert\\.pem}'")
	
	certBytes, err := cmd.CombinedOutput()
	if err != nil {
		// If cacerts doesn't exist, try istio-ca-secret
		cmd = exec.CommandContext(ctx, "kubectl", "get", "secret", "istio-ca-secret",
			"-n", i.config.Namespace, "-o", "jsonpath='{.data.root-cert\\.pem}'")
		
		certBytes, err = cmd.CombinedOutput()
		if err != nil {
			return "", fmt.Errorf("failed to get root certificate: %w, output: %s", err, string(certBytes))
		}
	}

	// Remove quotes and decode base64
	certStr := strings.Trim(string(certBytes), "'")
	certData, err := base64.StdEncoding.DecodeString(certStr)
	if err != nil {
		return "", fmt.Errorf("failed to decode root certificate: %w", err)
	}

	return string(certData), nil
}

func (i *IstioService) getIstiodAddress(ctx context.Context) (string, error) {
	// Get the external IP or LoadBalancer IP of istiod
	cmd := exec.CommandContext(ctx, "kubectl", "get", "svc", "istiod", 
		"-n", i.config.Namespace, "-o", "jsonpath='{.status.loadBalancer.ingress[0].ip}'")
	
	ipBytes, err := cmd.CombinedOutput()
	if err != nil {
		// Try to get external IP from nodes if LoadBalancer IP is not available
		cmd = exec.CommandContext(ctx, "kubectl", "get", "nodes",
			"-o", "jsonpath='{.items[0].status.addresses[?(@.type==\"ExternalIP\")].address}'")
		
		ipBytes, err = cmd.CombinedOutput()
		if err != nil {
			return "", fmt.Errorf("failed to get Istiod address: %w, output: %s", err, string(ipBytes))
		}
	}

	ip := strings.Trim(string(ipBytes), "'")
	if ip == "" {
		return "", fmt.Errorf("no external IP found for Istiod")
	}

	// Return IP with port
	return fmt.Sprintf("%s:15012", ip), nil
}