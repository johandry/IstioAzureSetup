package vmmanager
package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/johandry/IstioAzureSetup/internal/api"
	"github.com/johandry/IstioAzureSetup/internal/config"
	"github.com/johandry/IstioAzureSetup/internal/services"
	"github.com/sirupsen/logrus"
)

var (
	configPath = flag.String("config", "configs/config.yaml", "path to configuration file")
	port       = flag.String("port", "8080", "port to run the server on")
)

func main() {
	flag.Parse()

	// Load configuration
	cfg, err := config.Load(*configPath)
	if err != nil {
		logrus.Fatalf("Failed to load configuration: %v", err)
	}

	// Setup logging
	setupLogging(cfg.LogLevel)

	// Initialize services
	azureService, err := services.NewAzureService(cfg.Azure)
	if err != nil {
		logrus.Fatalf("Failed to initialize Azure service: %v", err)
	}

	kubeService, err := services.NewKubernetesService(cfg.Kubernetes)
	if err != nil {
		logrus.Fatalf("Failed to initialize Kubernetes service: %v", err)
	}

	istioService, err := services.NewIstioService(kubeService, cfg.Istio)
	if err != nil {
		logrus.Fatalf("Failed to initialize Istio service: %v", err)
	}

	vmService := services.NewVMService(azureService, kubeService, istioService, cfg)

	// Setup HTTP server
	if cfg.Environment == "production" {
		gin.SetMode(gin.ReleaseMode)
	}

	router := gin.New()
	router.Use(gin.Logger())
	router.Use(gin.Recovery())

	// Setup API routes
	apiHandler := api.NewHandler(vmService, azureService, kubeService, istioService)
	api.SetupRoutes(router, apiHandler)

	server := &http.Server{
		Addr:    fmt.Sprintf(":%s", *port),
		Handler: router,
	}

	// Start server in a goroutine
	go func() {
		logrus.Infof("Starting VM Manager server on port %s", *port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logrus.Fatalf("Failed to start server: %v", err)
		}
	}()

	// Wait for interrupt signal to gracefully shutdown the server
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	logrus.Info("Shutting down server...")

	// Give outstanding requests a deadline for completion
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		logrus.Fatalf("Server forced to shutdown: %v", err)
	}

	logrus.Info("Server exited")
}

func setupLogging(level string) {
	logrus.SetFormatter(&logrus.JSONFormatter{})
	
	switch level {
	case "debug":
		logrus.SetLevel(logrus.DebugLevel)
	case "info":
		logrus.SetLevel(logrus.InfoLevel)
	case "warn":
		logrus.SetLevel(logrus.WarnLevel)
	case "error":
		logrus.SetLevel(logrus.ErrorLevel)
	default:
		logrus.SetLevel(logrus.InfoLevel)
	}
}