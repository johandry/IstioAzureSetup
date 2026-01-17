package api
package api

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/johandry/IstioAzureSetup/internal/services"
	"github.com/sirupsen/logrus"
)

// Handler contains the service dependencies for API handlers
type Handler struct {
	vmService    *services.VMService
	azureService *services.AzureService
	kubeService  *services.KubernetesService
	istioService *services.IstioService
}

// NewHandler creates a new API handler
func NewHandler(vmService *services.VMService, azureService *services.AzureService, kubeService *services.KubernetesService, istioService *services.IstioService) *Handler {
	return &Handler{
		vmService:    vmService,
		azureService: azureService,
		kubeService:  kubeService,
		istioService: istioService,
	}
}

// Health check endpoint
func (h *Handler) Health(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"status": "healthy",
		"service": "vm-manager",
	})
}

// VM Management Endpoints

// CreateVM creates a new virtual machine
func (h *Handler) CreateVM(c *gin.Context) {
	var request services.VMRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	vm, err := h.azureService.CreateVM(c.Request.Context(), &request)
	if err != nil {
		logrus.Errorf("Failed to create VM: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusCreated, vm)
}

// DeployVM creates a VM with full mesh integration and post-boot tasks
func (h *Handler) DeployVM(c *gin.Context) {
	var request services.VMDeploymentRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	status, err := h.vmService.DeployVM(c.Request.Context(), &request)
	if err != nil {
		logrus.Errorf("Failed to deploy VM: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusAccepted, status)
}

// GetVM retrieves VM information
func (h *Handler) GetVM(c *gin.Context) {
	vmName := c.Param("name")
	if vmName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "VM name is required"})
		return
	}

	vm, err := h.azureService.GetVM(c.Request.Context(), vmName)
	if err != nil {
		logrus.Errorf("Failed to get VM: %v", err)
		c.JSON(http.StatusNotFound, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, vm)
}

// GetVMDeploymentStatus retrieves deployment status
func (h *Handler) GetVMDeploymentStatus(c *gin.Context) {
	vmName := c.Param("name")
	if vmName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "VM name is required"})
		return
	}

	status, err := h.vmService.GetVMDeploymentStatus(c.Request.Context(), vmName)
	if err != nil {
		logrus.Errorf("Failed to get VM deployment status: %v", err)
		c.JSON(http.StatusNotFound, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, status)
}

// ListVMs lists all virtual machines
func (h *Handler) ListVMs(c *gin.Context) {
	vms, err := h.azureService.ListVMs(c.Request.Context())
	if err != nil {
		logrus.Errorf("Failed to list VMs: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"vms":   vms,
		"count": len(vms),
	})
}

// DeleteVM deletes a virtual machine
func (h *Handler) DeleteVM(c *gin.Context) {
	vmName := c.Param("name")
	if vmName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "VM name is required"})
		return
	}

	err := h.azureService.DeleteVM(c.Request.Context(), vmName)
	if err != nil {
		logrus.Errorf("Failed to delete VM: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "VM deleted successfully"})
}

// CleanupDeployment removes all resources for a deployment
func (h *Handler) CleanupDeployment(c *gin.Context) {
	vmName := c.Param("name")
	if vmName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "VM name is required"})
		return
	}

	err := h.vmService.CleanupDeployment(c.Request.Context(), vmName)
	if err != nil {
		logrus.Errorf("Failed to cleanup deployment: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Deployment cleaned up successfully"})
}

// Istio Mesh Endpoints

// CreateWorkloadEntry creates an Istio WorkloadEntry
func (h *Handler) CreateWorkloadEntry(c *gin.Context) {
	var entry services.WorkloadEntry
	if err := c.ShouldBindJSON(&entry); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	err := h.kubeService.CreateWorkloadEntry(c.Request.Context(), &entry)
	if err != nil {
		logrus.Errorf("Failed to create WorkloadEntry: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"message": "WorkloadEntry created successfully"})
}

// GetWorkloadEntry retrieves a WorkloadEntry
func (h *Handler) GetWorkloadEntry(c *gin.Context) {
	name := c.Param("name")
	namespace := c.Query("namespace")
	
	if name == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "WorkloadEntry name is required"})
		return
	}

	entry, err := h.kubeService.GetWorkloadEntry(c.Request.Context(), name, namespace)
	if err != nil {
		logrus.Errorf("Failed to get WorkloadEntry: %v", err)
		c.JSON(http.StatusNotFound, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, entry)
}

// DeleteWorkloadEntry deletes a WorkloadEntry
func (h *Handler) DeleteWorkloadEntry(c *gin.Context) {
	name := c.Param("name")
	namespace := c.Query("namespace")
	
	if name == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "WorkloadEntry name is required"})
		return
	}

	err := h.kubeService.DeleteWorkloadEntry(c.Request.Context(), name, namespace)
	if err != nil {
		logrus.Errorf("Failed to delete WorkloadEntry: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "WorkloadEntry deleted successfully"})
}

// CreateServiceEntry creates an Istio ServiceEntry
func (h *Handler) CreateServiceEntry(c *gin.Context) {
	var entry services.ServiceEntry
	if err := c.ShouldBindJSON(&entry); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	err := h.kubeService.CreateServiceEntry(c.Request.Context(), &entry)
	if err != nil {
		logrus.Errorf("Failed to create ServiceEntry: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"message": "ServiceEntry created successfully"})
}

// GenerateVMFiles generates mesh integration files for a VM
func (h *Handler) GenerateVMFiles(c *gin.Context) {
	vmName := c.Param("name")
	vmIP := c.Query("ip")
	namespace := c.Query("namespace")

	if vmName == "" || vmIP == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "VM name and IP are required"})
		return
	}

	files, err := h.istioService.GenerateVMFiles(c.Request.Context(), vmName, vmIP, namespace)
	if err != nil {
		logrus.Errorf("Failed to generate VM files: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, files)
}

// GetMeshStatus retrieves Istio mesh status
func (h *Handler) GetMeshStatus(c *gin.Context) {
	status, err := h.istioService.GetMeshStatus(c.Request.Context())
	if err != nil {
		logrus.Errorf("Failed to get mesh status: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, status)
}

// ValidateVMConnection validates VM mesh connectivity
func (h *Handler) ValidateVMConnection(c *gin.Context) {
	vmIP := c.Query("ip")
	if vmIP == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "VM IP is required"})
		return
	}

	connected, err := h.istioService.ValidateVMConnection(c.Request.Context(), vmIP)
	if err != nil {
		logrus.Errorf("Failed to validate VM connection: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{
			"error":     err.Error(),
			"connected": false,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"connected": connected,
		"vm_ip":     vmIP,
	})
}

// Kubernetes Cluster Information

// GetClusterInfo retrieves Kubernetes cluster information
func (h *Handler) GetClusterInfo(c *gin.Context) {
	info, err := h.kubeService.GetClusterInfo(c.Request.Context())
	if err != nil {
		logrus.Errorf("Failed to get cluster info: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, info)
}

// GetNamespaces lists all Kubernetes namespaces
func (h *Handler) GetNamespaces(c *gin.Context) {
	namespaces, err := h.kubeService.GetNamespaces(c.Request.Context())
	if err != nil {
		logrus.Errorf("Failed to get namespaces: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"namespaces": namespaces,
		"count":      len(namespaces),
	})
}

// Utility endpoints

// GetVersion returns API version information
func (h *Handler) GetVersion(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"version":    "1.0.0",
		"api_version": "v1",
		"service":    "vm-manager",
		"features": []string{
			"vm_creation",
			"mesh_integration", 
			"post_boot_automation",
			"azure_integration",
			"istio_workload_entries",
		},
	})
}

// GetStats returns service statistics
func (h *Handler) GetStats(c *gin.Context) {
	// This could include metrics like:
	// - Number of VMs managed
	// - Success/failure rates
	// - Resource usage
	// For now, return basic info
	
	vms, _ := h.azureService.ListVMs(c.Request.Context())
	
	c.JSON(http.StatusOK, gin.H{
		"total_vms": len(vms),
		"timestamp": strconv.FormatInt(gin.H{}["timestamp"].(int64), 10),
	})
}