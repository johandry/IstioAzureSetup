package services
package services

import (
	"context"
	"encoding/base64"
	"fmt"
	"time"

	"github.com/johandry/IstioAzureSetup/internal/config"
	"github.com/sirupsen/logrus"
	"gopkg.in/yaml.v2"
)

// VMService orchestrates VM creation and mesh integration
type VMService struct {
	azureService *AzureService
	kubeService  *KubernetesService
	istioService *IstioService
	config       *config.Config
}

// VMDeploymentRequest represents a complete VM deployment request
type VMDeploymentRequest struct {
	VMRequest
	ServiceName        string            `json:"service_name,omitempty"`
	MeshIntegration    *MeshIntegration  `json:"mesh_integration,omitempty"`
	PostBootTasks      []PostBootTask    `json:"post_boot_tasks,omitempty"`
	AutoCleanup        bool              `json:"auto_cleanup,omitempty"`
	TimeoutMinutes     int               `json:"timeout_minutes,omitempty"`
}

// MeshIntegration contains mesh-specific configuration
type MeshIntegration struct {
	Enabled           bool              `json:"enabled"`
	Namespace         string            `json:"namespace,omitempty"`
	Labels            map[string]string `json:"labels,omitempty"`
	ServicePorts      []ServicePort     `json:"service_ports,omitempty"`
	CreateWorkloadEntry bool            `json:"create_workload_entry"`
	CreateServiceEntry  bool            `json:"create_service_entry"`
}

// PostBootTask represents a task to execute after VM boot
type PostBootTask struct {
	Name        string            `json:"name" binding:"required"`
	Type        string            `json:"type" binding:"required"` // "script", "validate", "wait"
	Command     string            `json:"command,omitempty"`
	ExpectedResult string         `json:"expected_result,omitempty"`
	TimeoutSeconds int            `json:"timeout_seconds,omitempty"`
	RetryCount  int               `json:"retry_count,omitempty"`
	Parameters  map[string]string `json:"parameters,omitempty"`
}

// VMDeploymentStatus represents the status of a VM deployment
type VMDeploymentStatus struct {
	VM              *VMInfo           `json:"vm"`
	Status          string            `json:"status"`
	CurrentTask     string            `json:"current_task,omitempty"`
	CompletedTasks  []string          `json:"completed_tasks"`
	Error           string            `json:"error,omitempty"`
	MeshFiles       *VMMeshFiles      `json:"mesh_files,omitempty"`
	CreatedResources []string         `json:"created_resources"`
	Timestamp       time.Time         `json:"timestamp"`
}

// NewVMService creates a new VM service instance
func NewVMService(azureService *AzureService, kubeService *KubernetesService, istioService *IstioService, config *config.Config) *VMService {
	return &VMService{
		azureService: azureService,
		kubeService:  kubeService,
		istioService: istioService,
		config:       config,
	}
}

// DeployVM deploys a VM with mesh integration and executes post-boot tasks
func (v *VMService) DeployVM(ctx context.Context, request *VMDeploymentRequest) (*VMDeploymentStatus, error) {
	logrus.Infof("Starting VM deployment: %s", request.Name)

	status := &VMDeploymentStatus{
		Status:           "initializing",
		CurrentTask:      "preparing_deployment",
		CompletedTasks:   []string{},
		CreatedResources: []string{},
		Timestamp:        time.Now(),
	}

	// Set timeout
	timeout := 30 * time.Minute
	if request.TimeoutMinutes > 0 {
		timeout = time.Duration(request.TimeoutMinutes) * time.Minute
	}

	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	// Step 1: Prepare cloud-init data
	status.CurrentTask = "generating_cloud_init"
	cloudInitData, err := v.generateCloudInitData(ctx, request)
	if err != nil {
		status.Status = "failed"
		status.Error = fmt.Sprintf("failed to generate cloud-init data: %v", err)
		return status, err
	}
	request.CloudInitData = cloudInitData
	status.CompletedTasks = append(status.CompletedTasks, "cloud_init_generated")

	// Step 2: Create the VM
	status.CurrentTask = "creating_vm"
	vm, err := v.azureService.CreateVM(ctx, &request.VMRequest)
	if err != nil {
		status.Status = "failed"
		status.Error = fmt.Sprintf("failed to create VM: %v", err)
		return status, err
	}
	status.VM = vm
	status.CreatedResources = append(status.CreatedResources, fmt.Sprintf("vm:%s", vm.Name))
	status.CompletedTasks = append(status.CompletedTasks, "vm_created")

	// Step 3: Wait for VM to be ready
	status.CurrentTask = "waiting_for_vm_ready"
	if err := v.waitForVMReady(ctx, vm.Name, 10*time.Minute); err != nil {
		status.Status = "failed"
		status.Error = fmt.Sprintf("VM failed to become ready: %v", err)
		if request.AutoCleanup {
			v.cleanupDeployment(ctx, request.Name, status.CreatedResources)
		}
		return status, err
	}
	status.CompletedTasks = append(status.CompletedTasks, "vm_ready")

	// Step 4: Generate mesh files if mesh integration is enabled
	if request.MeshIntegration != nil && request.MeshIntegration.Enabled {
		status.CurrentTask = "generating_mesh_files"
		meshFiles, err := v.istioService.GenerateVMFiles(ctx, vm.Name, vm.PrivateIP, request.MeshIntegration.Namespace)
		if err != nil {
			status.Status = "failed"
			status.Error = fmt.Sprintf("failed to generate mesh files: %v", err)
			if request.AutoCleanup {
				v.cleanupDeployment(ctx, request.Name, status.CreatedResources)
			}
			return status, err
		}
		status.MeshFiles = meshFiles
		status.CompletedTasks = append(status.CompletedTasks, "mesh_files_generated")

		// Step 5: Create WorkloadEntry if requested
		if request.MeshIntegration.CreateWorkloadEntry {
			status.CurrentTask = "creating_workload_entry"
			if err := v.istioService.CreateWorkloadEntryForVM(ctx, vm.Name, vm.PrivateIP, request.MeshIntegration.Namespace, request.MeshIntegration.Labels); err != nil {
				logrus.Warnf("Failed to create WorkloadEntry: %v", err)
			} else {
				workloadEntryName := fmt.Sprintf("vm-%s", vm.Name)
				status.CreatedResources = append(status.CreatedResources, fmt.Sprintf("workloadentry:%s", workloadEntryName))
				status.CompletedTasks = append(status.CompletedTasks, "workload_entry_created")
			}
		}

		// Step 6: Create ServiceEntry if requested
		if request.MeshIntegration.CreateServiceEntry && request.ServiceName != "" {
			status.CurrentTask = "creating_service_entry"
			if err := v.istioService.CreateServiceEntryForVM(ctx, vm.Name, vm.PrivateIP, request.ServiceName, request.MeshIntegration.Namespace); err != nil {
				logrus.Warnf("Failed to create ServiceEntry: %v", err)
			} else {
				serviceEntryName := fmt.Sprintf("vm-%s-service", vm.Name)
				status.CreatedResources = append(status.CreatedResources, fmt.Sprintf("serviceentry:%s", serviceEntryName))
				status.CompletedTasks = append(status.CompletedTasks, "service_entry_created")
			}
		}
	}

	// Step 7: Execute post-boot tasks
	if request.PostBootTasks != nil && len(request.PostBootTasks) > 0 {
		for _, task := range request.PostBootTasks {
			status.CurrentTask = fmt.Sprintf("executing_task_%s", task.Name)
			if err := v.executePostBootTask(ctx, vm, &task); err != nil {
				logrus.Warnf("Failed to execute post-boot task %s: %v", task.Name, err)
				// Continue with other tasks unless it's a critical task
			} else {
				status.CompletedTasks = append(status.CompletedTasks, fmt.Sprintf("task_%s_completed", task.Name))
			}
		}
	}

	// Step 8: Final validation
	status.CurrentTask = "final_validation"
	if request.MeshIntegration != nil && request.MeshIntegration.Enabled {
		if connected, err := v.istioService.ValidateVMConnection(ctx, vm.PrivateIP); err != nil || !connected {
			logrus.Warnf("VM mesh validation failed: %v", err)
		} else {
			status.CompletedTasks = append(status.CompletedTasks, "mesh_validation_passed")
		}
	}

	status.Status = "completed"
	status.CurrentTask = ""
	status.Timestamp = time.Now()

	logrus.Infof("VM deployment completed successfully: %s", request.Name)
	return status, nil
}

// GetVMDeploymentStatus retrieves the current status of a VM deployment
func (v *VMService) GetVMDeploymentStatus(ctx context.Context, vmName string) (*VMDeploymentStatus, error) {
	vm, err := v.azureService.GetVM(ctx, vmName)
	if err != nil {
		return nil, fmt.Errorf("failed to get VM info: %w", err)
	}

	status := &VMDeploymentStatus{
		VM:        vm,
		Status:    "running",
		Timestamp: time.Now(),
	}

	return status, nil
}

// CleanupDeployment removes all resources created during deployment
func (v *VMService) CleanupDeployment(ctx context.Context, vmName string) error {
	logrus.Infof("Cleaning up deployment: %s", vmName)

	// Cleanup Istio resources
	if err := v.istioService.CleanupVMResources(ctx, vmName, ""); err != nil {
		logrus.Warnf("Failed to cleanup Istio resources: %v", err)
	}

	// Delete VM and associated resources
	if err := v.azureService.DeleteVM(ctx, vmName); err != nil {
		return fmt.Errorf("failed to delete VM: %w", err)
	}

	logrus.Infof("Deployment cleanup completed: %s", vmName)
	return nil
}

// Helper methods

func (v *VMService) generateCloudInitData(ctx context.Context, request *VMDeploymentRequest) (string, error) {
	// Base cloud-init configuration
	cloudInit := map[string]interface{}{
		"package_update": true,
		"package_upgrade": true,
		"packages": []string{
			"curl",
			"wget",
			"unzip",
			"jq",
			"docker.io",
			"docker-compose",
		},
		"runcmd": []string{
			"systemctl enable docker",
			"systemctl start docker",
			"usermod -aG docker ubuntu",
			"curl -L https://istio.io/downloadIstio | sh -",
			"sudo mv istio-*/bin/istioctl /usr/local/bin/",
			"mkdir -p /etc/istio-vm",
		},
		"write_files": []map[string]interface{}{},
	}

	// Add mesh integration files if enabled
	if request.MeshIntegration != nil && request.MeshIntegration.Enabled {
		// We'll add placeholder files here - actual content will be provided via separate mechanism
		meshFiles := []map[string]interface{}{
			{
				"path":        "/etc/istio-vm/cluster.env",
				"content":     "# Placeholder for cluster.env",
				"permissions": "0644",
			},
			{
				"path":        "/etc/istio-vm/mesh.yaml", 
				"content":     "# Placeholder for mesh.yaml",
				"permissions": "0644",
			},
			{
				"path":        "/etc/istio-vm/istio-token",
				"content":     "# Placeholder for istio-token",
				"permissions": "0600",
			},
		}
		
		writeFiles := cloudInit["write_files"].([]map[string]interface{})
		cloudInit["write_files"] = append(writeFiles, meshFiles...)

		// Add Istio setup commands
		runcmd := cloudInit["runcmd"].([]string)
		istioCommands := []string{
			"# Install Istio sidecar",
			"curl -LO https://storage.googleapis.com/istio-release/releases/1.19.3/deb/istio-sidecar.deb",
			"sudo dpkg -i istio-sidecar.deb",
		}
		cloudInit["runcmd"] = append(runcmd, istioCommands...)
	}

	// Convert to YAML
	yamlData, err := yaml.Marshal(cloudInit)
	if err != nil {
		return "", fmt.Errorf("failed to marshal cloud-init data: %w", err)
	}

	// Add cloud-config header
	cloudInitStr := "#cloud-config\n" + string(yamlData)

	// Encode to base64 for Azure
	return base64.StdEncoding.EncodeToString([]byte(cloudInitStr)), nil
}

func (v *VMService) waitForVMReady(ctx context.Context, vmName string, timeout time.Duration) error {
	logrus.Infof("Waiting for VM to be ready: %s", vmName)

	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("timeout waiting for VM to be ready")
		case <-ticker.C:
			vm, err := v.azureService.GetVM(ctx, vmName)
			if err != nil {
				logrus.Warnf("Failed to check VM status: %v", err)
				continue
			}

			if vm.Status == "VM running" {
				logrus.Infof("VM is ready: %s", vmName)
				return nil
			}

			logrus.Infof("VM status: %s, waiting...", vm.Status)
		}
	}
}

func (v *VMService) executePostBootTask(ctx context.Context, vm *VMInfo, task *PostBootTask) error {
	logrus.Infof("Executing post-boot task: %s", task.Name)

	// Set task timeout
	timeout := 5 * time.Minute
	if task.TimeoutSeconds > 0 {
		timeout = time.Duration(task.TimeoutSeconds) * time.Second
	}

	taskCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	switch task.Type {
	case "wait":
		// Wait for a specified duration
		duration := 60 * time.Second
		if durationStr, ok := task.Parameters["duration"]; ok {
			if d, err := time.ParseDuration(durationStr); err == nil {
				duration = d
			}
		}
		
		logrus.Infof("Waiting for %v", duration)
		time.Sleep(duration)
		return nil

	case "validate":
		// Validate connectivity or service availability
		return v.validateVMService(taskCtx, vm, task)

	case "script":
		// Execute a script (this would require SSH access)
		logrus.Warnf("Script execution not implemented yet: %s", task.Command)
		return nil

	default:
		return fmt.Errorf("unknown task type: %s", task.Type)
	}
}

func (v *VMService) validateVMService(ctx context.Context, vm *VMInfo, task *PostBootTask) error {
	// This is a simplified validation
	// In production, you might want to SSH into the VM or check specific endpoints
	
	if vm.Status != "VM running" {
		return fmt.Errorf("VM is not running: %s", vm.Status)
	}

	// Additional validations based on task parameters
	if endpoint, ok := task.Parameters["endpoint"]; ok {
		logrus.Infof("Validating endpoint: %s", endpoint)
		// Here you could make HTTP requests to validate service availability
	}

	return nil
}

func (v *VMService) cleanupDeployment(ctx context.Context, vmName string, createdResources []string) {
	logrus.Infof("Auto-cleanup enabled, removing created resources for: %s", vmName)
	
	for _, resource := range createdResources {
		logrus.Infof("Cleaning up resource: %s", resource)
		// Parse resource type and name, then cleanup accordingly
	}

	// Always try to cleanup the VM
	if err := v.azureService.DeleteVM(ctx, vmName); err != nil {
		logrus.Errorf("Failed to cleanup VM during auto-cleanup: %v", err)
	}
}