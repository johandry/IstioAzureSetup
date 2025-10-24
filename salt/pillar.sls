# Salt Pillar Configuration for Istio VM Setup
# This file contains configuration data that can be referenced in Salt states

# Istio Configuration
istio:
  version: "1.27.0"
  download_url: "https://storage.googleapis.com/istio-release/releases"
  sidecar_package: "istio-sidecar.deb"
  
  # Directories
  directories:
    certs: /etc/certs
    tokens: /var/run/secrets/tokens
    istio_secrets: /var/run/secrets/istio/
    proxy: /etc/istio/proxy
    config: /etc/istio/config
    envoy: /var/lib/istio/envoy
    base: /etc/istio

  # Service configuration
  service:
    name: istio
    enable: true
    
  # Ports configuration
  ports:
    admin: 15000
    stats: 15000
    discovery: 15012
    sidecar_range_start: 15000
    sidecar_range_end: 15090

# Azure VM Configuration
azure:
  user: azureuser
  home_dir: /home/azureuser
  
  # Required packages
  packages:
    - curl
    - iptables
    - wget
    - systemd
    - unzip
    - ufw
    - python3
    - python3-pip

# Firewall Configuration
firewall:
  rules:
    ssh:
      port: 22
      protocol: tcp
      comment: 'SSH management'
    istio_sidecar:
      port_range: '15000:15090'
      protocol: tcp
      comment: 'Istio sidecar ports'
    istio_discovery:
      port: 15012
      protocol: tcp
      direction: out
      comment: 'Istio discovery'

# Logging Configuration
logging:
  boot_log: /var/log/istio-boot.log
  retention_days: 30

# Health Check Configuration
health_check:
  timeout: 30
  retry_interval: 2
  max_retries: 30
  endpoints:
    - http://localhost:15000/ready
    - http://localhost:15000/stats/prometheus

# Environment-specific configurations can be set here
environments:
  production:
    log_level: INFO
    health_check_interval: 60
  staging:
    log_level: DEBUG  
    health_check_interval: 30
  development:
    log_level: DEBUG
    health_check_interval: 15