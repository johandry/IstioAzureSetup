package services
package services

import (
	"context"
	"fmt"
	"path/filepath"
	"os"

	"github.com/johandry/IstioAzureSetup/internal/config"
	"github.com/sirupsen/logrus"
	"k8s.io/api/networking/v1beta1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// KubernetesService handles Kubernetes operations
type KubernetesService struct {
	config        config.KubernetesConfig
	clientset     *kubernetes.Clientset
	dynamicClient dynamic.Interface
	restConfig    *rest.Config
}

// WorkloadEntry represents an Istio WorkloadEntry
type WorkloadEntry struct {
	Name      string            `json:"name" binding:"required"`
	Namespace string            `json:"namespace,omitempty"`
	Address   string            `json:"address" binding:"required"`
	Network   string            `json:"network,omitempty"`
	Labels    map[string]string `json:"labels,omitempty"`
	Ports     map[string]uint32 `json:"ports,omitempty"`
}

// ServiceEntry represents an Istio ServiceEntry
type ServiceEntry struct {
	Name      string            `json:"name" binding:"required"`
	Namespace string            `json:"namespace,omitempty"`
	Hosts     []string          `json:"hosts" binding:"required"`
	Location  string            `json:"location,omitempty"` // MESH_EXTERNAL or MESH_INTERNAL
	Ports     []ServicePort     `json:"ports,omitempty"`
	Endpoints []WorkloadEndpoint `json:"endpoints,omitempty"`
}

// ServicePort represents a port in ServiceEntry
type ServicePort struct {
	Number   uint32 `json:"number" binding:"required"`
	Name     string `json:"name" binding:"required"`
	Protocol string `json:"protocol,omitempty"`
}

// WorkloadEndpoint represents an endpoint in ServiceEntry
type WorkloadEndpoint struct {
	Address string            `json:"address" binding:"required"`
	Network string            `json:"network,omitempty"`
	Ports   map[string]uint32 `json:"ports,omitempty"`
}

// NewKubernetesService creates a new Kubernetes service instance
func NewKubernetesService(config config.KubernetesConfig) (*KubernetesService, error) {
	var restConfig *rest.Config
	var err error

	// Try to load kubeconfig from specified path
	if config.ConfigPath != "" {
		// Expand environment variables in path
		kubeconfig := os.ExpandEnv(config.ConfigPath)
		restConfig, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
	} else {
		// Try in-cluster config first
		restConfig, err = rest.InClusterConfig()
		if err != nil {
			// Fall back to default kubeconfig location
			home, _ := os.UserHomeDir()
			kubeconfig := filepath.Join(home, ".kube", "config")
			restConfig, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
		}
	}

	if err != nil {
		return nil, fmt.Errorf("failed to create Kubernetes config: %w", err)
	}

	// Create clientset
	clientset, err := kubernetes.NewForConfig(restConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to create Kubernetes clientset: %w", err)
	}

	// Create dynamic client for custom resources
	dynamicClient, err := dynamic.NewForConfig(restConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to create dynamic client: %w", err)
	}

	return &KubernetesService{
		config:        config,
		clientset:     clientset,
		dynamicClient: dynamicClient,
		restConfig:    restConfig,
	}, nil
}

// CreateWorkloadEntry creates an Istio WorkloadEntry
func (k *KubernetesService) CreateWorkloadEntry(ctx context.Context, entry *WorkloadEntry) error {
	logrus.Infof("Creating WorkloadEntry: %s", entry.Name)

	namespace := entry.Namespace
	if namespace == "" {
		namespace = k.config.Namespace
	}

	// Define WorkloadEntry GVR
	workloadEntryGVR := schema.GroupVersionResource{
		Group:    "networking.istio.io",
		Version:  "v1beta1",
		Resource: "workloadentries",
	}

	// Build WorkloadEntry object
	workloadEntry := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "networking.istio.io/v1beta1",
			"kind":       "WorkloadEntry",
			"metadata": map[string]interface{}{
				"name":      entry.Name,
				"namespace": namespace,
			},
			"spec": map[string]interface{}{
				"address": entry.Address,
			},
		},
	}

	// Add optional fields
	spec := workloadEntry.Object["spec"].(map[string]interface{})

	if entry.Network != "" {
		spec["network"] = entry.Network
	}

	if entry.Labels != nil && len(entry.Labels) > 0 {
		spec["labels"] = entry.Labels
	}

	if entry.Ports != nil && len(entry.Ports) > 0 {
		spec["ports"] = entry.Ports
	}

	// Create WorkloadEntry
	_, err := k.dynamicClient.Resource(workloadEntryGVR).Namespace(namespace).Create(ctx, workloadEntry, metav1.CreateOptions{})
	if err != nil {
		return fmt.Errorf("failed to create WorkloadEntry: %w", err)
	}

	logrus.Infof("Successfully created WorkloadEntry: %s in namespace: %s", entry.Name, namespace)
	return nil
}

// GetWorkloadEntry retrieves a WorkloadEntry
func (k *KubernetesService) GetWorkloadEntry(ctx context.Context, name, namespace string) (*WorkloadEntry, error) {
	if namespace == "" {
		namespace = k.config.Namespace
	}

	workloadEntryGVR := schema.GroupVersionResource{
		Group:    "networking.istio.io",
		Version:  "v1beta1",
		Resource: "workloadentries",
	}

	obj, err := k.dynamicClient.Resource(workloadEntryGVR).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("failed to get WorkloadEntry: %w", err)
	}

	// Convert unstructured to WorkloadEntry
	spec, found, err := unstructured.NestedMap(obj.Object, "spec")
	if err != nil || !found {
		return nil, fmt.Errorf("failed to extract spec from WorkloadEntry")
	}

	entry := &WorkloadEntry{
		Name:      name,
		Namespace: namespace,
	}

	if address, found, _ := unstructured.NestedString(spec, "address"); found {
		entry.Address = address
	}

	if network, found, _ := unstructured.NestedString(spec, "network"); found {
		entry.Network = network
	}

	if labels, found, _ := unstructured.NestedStringMap(spec, "labels"); found {
		entry.Labels = labels
	}

	if ports, found, _ := unstructured.NestedMap(spec, "ports"); found {
		entry.Ports = make(map[string]uint32)
		for k, v := range ports {
			if portNum, ok := v.(int64); ok {
				entry.Ports[k] = uint32(portNum)
			}
		}
	}

	return entry, nil
}

// DeleteWorkloadEntry deletes a WorkloadEntry
func (k *KubernetesService) DeleteWorkloadEntry(ctx context.Context, name, namespace string) error {
	if namespace == "" {
		namespace = k.config.Namespace
	}

	logrus.Infof("Deleting WorkloadEntry: %s from namespace: %s", name, namespace)

	workloadEntryGVR := schema.GroupVersionResource{
		Group:    "networking.istio.io",
		Version:  "v1beta1",
		Resource: "workloadentries",
	}

	err := k.dynamicClient.Resource(workloadEntryGVR).Namespace(namespace).Delete(ctx, name, metav1.DeleteOptions{})
	if err != nil {
		return fmt.Errorf("failed to delete WorkloadEntry: %w", err)
	}

	logrus.Infof("Successfully deleted WorkloadEntry: %s", name)
	return nil
}

// CreateServiceEntry creates an Istio ServiceEntry
func (k *KubernetesService) CreateServiceEntry(ctx context.Context, entry *ServiceEntry) error {
	logrus.Infof("Creating ServiceEntry: %s", entry.Name)

	namespace := entry.Namespace
	if namespace == "" {
		namespace = k.config.Namespace
	}

	serviceEntryGVR := schema.GroupVersionResource{
		Group:    "networking.istio.io",
		Version:  "v1beta1",
		Resource: "serviceentries",
	}

	// Build ServiceEntry object
	serviceEntry := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "networking.istio.io/v1beta1",
			"kind":       "ServiceEntry",
			"metadata": map[string]interface{}{
				"name":      entry.Name,
				"namespace": namespace,
			},
			"spec": map[string]interface{}{
				"hosts": entry.Hosts,
			},
		},
	}

	// Add optional fields
	spec := serviceEntry.Object["spec"].(map[string]interface{})

	if entry.Location != "" {
		spec["location"] = entry.Location
	} else {
		spec["location"] = "MESH_EXTERNAL"
	}

	if entry.Ports != nil && len(entry.Ports) > 0 {
		ports := make([]map[string]interface{}, len(entry.Ports))
		for i, port := range entry.Ports {
			portMap := map[string]interface{}{
				"number": port.Number,
				"name":   port.Name,
			}
			if port.Protocol != "" {
				portMap["protocol"] = port.Protocol
			} else {
				portMap["protocol"] = "HTTP"
			}
			ports[i] = portMap
		}
		spec["ports"] = ports
	}

	if entry.Endpoints != nil && len(entry.Endpoints) > 0 {
		endpoints := make([]map[string]interface{}, len(entry.Endpoints))
		for i, endpoint := range entry.Endpoints {
			endpointMap := map[string]interface{}{
				"address": endpoint.Address,
			}
			if endpoint.Network != "" {
				endpointMap["network"] = endpoint.Network
			}
			if endpoint.Ports != nil {
				endpointMap["ports"] = endpoint.Ports
			}
			endpoints[i] = endpointMap
		}
		spec["endpoints"] = endpoints
	}

	// Create ServiceEntry
	_, err := k.dynamicClient.Resource(serviceEntryGVR).Namespace(namespace).Create(ctx, serviceEntry, metav1.CreateOptions{})
	if err != nil {
		return fmt.Errorf("failed to create ServiceEntry: %w", err)
	}

	logrus.Infof("Successfully created ServiceEntry: %s in namespace: %s", entry.Name, namespace)
	return nil
}

// DeleteServiceEntry deletes a ServiceEntry
func (k *KubernetesService) DeleteServiceEntry(ctx context.Context, name, namespace string) error {
	if namespace == "" {
		namespace = k.config.Namespace
	}

	logrus.Infof("Deleting ServiceEntry: %s from namespace: %s", name, namespace)

	serviceEntryGVR := schema.GroupVersionResource{
		Group:    "networking.istio.io",
		Version:  "v1beta1",
		Resource: "serviceentries",
	}

	err := k.dynamicClient.Resource(serviceEntryGVR).Namespace(namespace).Delete(ctx, name, metav1.DeleteOptions{})
	if err != nil {
		return fmt.Errorf("failed to delete ServiceEntry: %w", err)
	}

	logrus.Infof("Successfully deleted ServiceEntry: %s", name)
	return nil
}

// GetNamespaces lists all namespaces
func (k *KubernetesService) GetNamespaces(ctx context.Context) ([]string, error) {
	namespaces, err := k.clientset.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("failed to list namespaces: %w", err)
	}

	var names []string
	for _, ns := range namespaces.Items {
		names = append(names, ns.Name)
	}

	return names, nil
}

// CreateSecret creates a Kubernetes secret
func (k *KubernetesService) CreateSecret(ctx context.Context, name, namespace string, data map[string][]byte) error {
	if namespace == "" {
		namespace = k.config.Namespace
	}

	secret := &v1beta1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
		},
		Data: data,
	}

	_, err := k.clientset.CoreV1().Secrets(namespace).Create(ctx, secret, metav1.CreateOptions{})
	if err != nil {
		return fmt.Errorf("failed to create secret: %w", err)
	}

	logrus.Infof("Successfully created secret: %s in namespace: %s", name, namespace)
	return nil
}

// GetClusterInfo retrieves basic cluster information
func (k *KubernetesService) GetClusterInfo(ctx context.Context) (map[string]interface{}, error) {
	version, err := k.clientset.Discovery().ServerVersion()
	if err != nil {
		return nil, fmt.Errorf("failed to get server version: %w", err)
	}

	nodes, err := k.clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("failed to list nodes: %w", err)
	}

	namespaces, err := k.GetNamespaces(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get namespaces: %w", err)
	}

	info := map[string]interface{}{
		"version": map[string]string{
			"major":      version.Major,
			"minor":      version.Minor,
			"gitVersion": version.GitVersion,
			"platform":   version.Platform,
		},
		"nodes":      len(nodes.Items),
		"namespaces": namespaces,
	}

	return info, nil
}