package api

import (
	"github.com/gin-gonic/gin"
)

// SetupRoutes configures all API routes
func SetupRoutes(router *gin.Engine, handler *Handler) {
	// Health check
	router.GET("/health", handler.Health)
	router.GET("/version", handler.GetVersion)
	router.GET("/stats", handler.GetStats)

	// API v1 group
	v1 := router.Group("/api/v1")
	{
		// VM Management Routes
		vm := v1.Group("/vms")
		{
			vm.POST("", handler.CreateVM)                    // Create a basic VM
			vm.POST("/deploy", handler.DeployVM)             // Deploy VM with full integration
			vm.GET("", handler.ListVMs)                      // List all VMs
			vm.GET("/:name", handler.GetVM)                  // Get specific VM
			vm.DELETE("/:name", handler.DeleteVM)            // Delete VM
			vm.GET("/:name/status", handler.GetVMDeploymentStatus) // Get deployment status
			vm.DELETE("/:name/cleanup", handler.CleanupDeployment) // Cleanup all resources
		}

		// Istio Mesh Integration Routes
		mesh := v1.Group("/mesh")
		{
			mesh.GET("/status", handler.GetMeshStatus)           // Get mesh status
			mesh.GET("/validate", handler.ValidateVMConnection)  // Validate VM connection
			
			// WorkloadEntry management
			workloadEntries := mesh.Group("/workload-entries")
			{
				workloadEntries.POST("", handler.CreateWorkloadEntry)    // Create WorkloadEntry
				workloadEntries.GET("/:name", handler.GetWorkloadEntry)  // Get WorkloadEntry
				workloadEntries.DELETE("/:name", handler.DeleteWorkloadEntry) // Delete WorkloadEntry
			}

			// ServiceEntry management
			serviceEntries := mesh.Group("/service-entries")
			{
				serviceEntries.POST("", handler.CreateServiceEntry)      // Create ServiceEntry
			}

			// VM mesh files generation
			mesh.GET("/vm/:name/files", handler.GenerateVMFiles)     // Generate VM mesh files
		}

		// Kubernetes Cluster Routes
		cluster := v1.Group("/cluster")
		{
			cluster.GET("/info", handler.GetClusterInfo)         // Get cluster information
			cluster.GET("/namespaces", handler.GetNamespaces)    // List namespaces
		}
	}

	// Add middleware for logging and CORS if needed
	router.Use(corsMiddleware())
	router.Use(loggingMiddleware())
}

// corsMiddleware handles CORS headers
func corsMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Content-Type, Authorization")
		
		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(204)
			return
		}
		
		c.Next()
	}
}

// loggingMiddleware adds request/response logging
func loggingMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		// Log request details
		c.Next()
		
		// Log response details if needed
	}
}