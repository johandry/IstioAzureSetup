package config
package config

import (
	"io/ioutil"
	"gopkg.in/yaml.v2"
)

// Config represents the application configuration
type Config struct {
	Environment string            `yaml:"environment"`
	LogLevel    string            `yaml:"log_level"`
	Azure       AzureConfig       `yaml:"azure"`
	Kubernetes  KubernetesConfig  `yaml:"kubernetes"`
	Istio       IstioConfig       `yaml:"istio"`
	VM          VMConfig          `yaml:"vm"`
}

// AzureConfig contains Azure-specific configuration
type AzureConfig struct {
	SubscriptionID    string `yaml:"subscription_id"`
	TenantID          string `yaml:"tenant_id"`
	ClientID          string `yaml:"client_id"`
	ClientSecret      string `yaml:"client_secret"`
	Location          string `yaml:"location"`
	ResourceGroupName string `yaml:"resource_group_name"`
}

// KubernetesConfig contains Kubernetes cluster configuration
type KubernetesConfig struct {
	ConfigPath  string `yaml:"config_path"`
	Context     string `yaml:"context"`
	Namespace   string `yaml:"namespace"`
}

// IstioConfig contains Istio-specific configuration
type IstioConfig struct {
	MeshID      string `yaml:"mesh_id"`
	Network     string `yaml:"network"`
	ClusterName string `yaml:"cluster_name"`
	Namespace   string `yaml:"namespace"`
}

// VMConfig contains VM-specific configuration
type VMConfig struct {
	DefaultSize           string            `yaml:"default_size"`
	DefaultImage          VMImageConfig     `yaml:"default_image"`
	DefaultNetworking     NetworkingConfig  `yaml:"default_networking"`
	CloudInitTemplatePath string            `yaml:"cloud_init_template_path"`
	Tags                  map[string]string `yaml:"tags"`
}

// VMImageConfig defines the default VM image
type VMImageConfig struct {
	Publisher string `yaml:"publisher"`
	Offer     string `yaml:"offer"`
	SKU       string `yaml:"sku"`
	Version   string `yaml:"version"`
}

// NetworkingConfig defines default networking configuration
type NetworkingConfig struct {
	VNetName           string `yaml:"vnet_name"`
	SubnetName         string `yaml:"subnet_name"`
	SecurityGroupName  string `yaml:"security_group_name"`
	PublicIPEnabled    bool   `yaml:"public_ip_enabled"`
}

// Load reads and parses the configuration file
func Load(configPath string) (*Config, error) {
	data, err := ioutil.ReadFile(configPath)
	if err != nil {
		return nil, err
	}

	var config Config
	if err := yaml.Unmarshal(data, &config); err != nil {
		return nil, err
	}

	return &config, nil
}