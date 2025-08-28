#!/bin/bash

# VM Mesh Setup Script (to be run on the VM)
# This script configures the VM as a workload in the Istio mesh
set -e

WORK_DIR="/home/azureuser/istio-vm-setup"
SERVICE_ACCOUNT="vm-workload"
NAMESPACE="vm-workloads"
VM_APP="vm-web-service"

print_status() {
    echo -e "\033[0;32m[INFO]\033[0m $1"
}

print_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1"
}

print_warning() {
    echo -e "\033[1;33m[WARNING]\033[0m $1"
}

# Validate prerequisites
validate_prerequisites() {
    print_status "Validating prerequisites for Istio VM integration..."
    
    # Check if running as correct user
    if [ "$USER" != "azureuser" ]; then
        print_warning "Script should be run as azureuser, current user: $USER"
    fi
    
    # Check if required files exist
    if [ ! -d "/tmp/vm-files" ]; then
        print_error "VM files directory not found. Please ensure files were transferred correctly."
        exit 1
    fi
    
    # Check for required files
    local required_files=("istio-token" "root-cert.pem" "cluster.env" "mesh.yaml" "hosts")
    for file in "${required_files[@]}"; do
        if [ ! -f "/tmp/vm-files/$file" ]; then
            print_error "Required file not found: $file"
            exit 1
        fi
    done
    
    print_status "Prerequisites validation passed"
}

# Install required packages for service hosting and Istio sidecar
install_packages() {
    print_status "Installing required packages for VM service and Istio integration..."
    
    # Update package list
    sudo apt update
    
    # Install required packages
    sudo apt install -y curl python3 python3-pip iptables wget systemd unzip
    
    # Install Python packages for web service
    pip3 install --user flask gunicorn
    
    print_status "Basic packages installed successfully"
}

# Install and configure Istio certificates for workload integration
install_istio_certificates() {
    print_status "Installing Istio workload integration certificates..."
    
    # Create working directory
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # Copy configuration files from cluster (transferred separately)
    if [ -d "/tmp/vm-files" ]; then
        cp /tmp/vm-files/* . 2>/dev/null || true
    fi
    
    # Create necessary directories for Istio workload integration
    sudo mkdir -p /etc/certs
    sudo mkdir -p /var/run/secrets/tokens
    sudo mkdir -p /var/run/secrets/istio/
    
    # Copy certificates
    if [ -f "root-cert.pem" ]; then
        sudo cp root-cert.pem /etc/certs/
        sudo chmod 644 /etc/certs/root-cert.pem
        sudo cp /etc/certs/root-cert.pem /var/run/secrets/istio/
        print_status "✓ Root certificate configured"
    else
        print_error "Root certificate not found"
        exit 1
    fi
    
    # Copy Istio token (CRITICAL for authentication)
    if [ -f "istio-token" ]; then
        sudo cp istio-token /var/run/secrets/tokens/istio-token
        sudo chmod 644 /var/run/secrets/tokens/istio-token
        print_status "✓ Istio service account token configured"
    else
        print_error "Istio token not found - VM will not be able to authenticate with mesh"
        exit 1
    fi
}

# Download and install Istio with proper error handling
install_istio() {
    print_status "Installing Istio (Envoy)..."
    
    ISTIO_VERSION="1.27.0"
    DOWNLOAD_DIR="/tmp/istio-download"
    
    # Check if pilot-agent is already installed
    if [ -f "/usr/local/bin/pilot-agent" ]; then
        print_status "✓ Istio already installed"
        # Verify it works
        if /usr/local/bin/pilot-agent version &>/dev/null; then
            print_status "✓ Pilot agent installation verified"
            return 0
        else
            print_warning "Existing pilot-agent installation appears corrupted, reinstalling..."
            sudo rm -f /usr/local/bin/pilot-agent
        fi
    fi
    
    # Create temporary download directory
    mkdir -p "$DOWNLOAD_DIR"
    cd "$DOWNLOAD_DIR"
    
    # Clean up any previous downloads
    rm -rf istio-* 2>/dev/null || true
    
    print_status "Downloading Istio ${ISTIO_VERSION}..."
    
    # Download with proper error handling
    if ! wget -q --timeout=30 --tries=3 "https://storage.googleapis.com/istio-release/releases/${ISTIO_VERSION}/deb/istio-sidecar.deb"; then
        print_error "Failed to download Istio ${ISTIO_VERSION}"
        print_error "Please check internet connectivity and try again"
        cd /home/azureuser
        rm -rf "$DOWNLOAD_DIR"
        exit 1
    fi
    
    # Verify download
    if [ ! -f "istio-sidecar.deb" ]; then
        print_error "Istio download file not found after download"
        cd /home/azureuser
        rm -rf "$DOWNLOAD_DIR"
        exit 1
    fi
    
    print_status "Installing Istio..."
    
    # Installing with proper error handling and permissions
    if ! sudo dpkg -i istio-sidecar.deb; then
        print_error "Failed to install Istio package"
        print_error "Package may be corrupted or incomplete"
        cd /home/azureuser
        rm -rf "$DOWNLOAD_DIR"
        exit 1
    fi
    
    # Verify installation
    if /usr/local/bin/pilot-agent version &>/dev/null; then
        print_status "✓ Istio installed successfully"
    else
        print_error "Pilot agent installation verification failed"
        cd /home/azureuser
        rm -rf "$DOWNLOAD_DIR"
        exit 1
    fi
    
    # Cleanup download directory
    cd /home/azureuser
    rm -rf "$DOWNLOAD_DIR"
    
    print_status "✓ Istio installation completed"
}

# Install and configure Istio components for workload integration
install_istio_components() {
    print_status "Installing Istio workload integration components..."
    
    # Create working directory
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # Copy configuration files from cluster (transferred separately)
    if [ -d "/tmp/vm-files" ]; then
        cp /tmp/vm-files/* . 2>/dev/null || true
    fi
    
    # Create necessary directories for Istio workload integration
    sudo mkdir -p /etc/istio/proxy
    sudo mkdir -p /etc/istio/config
    sudo mkdir -p /var/lib/istio/envoy
    sudo mkdir -p /etc/istio
    
    # Copy mesh configuration
    if [ -f "mesh.yaml" ]; then
        sudo cp mesh.yaml /etc/istio/config/mesh
        sudo chmod 644 /etc/istio/config/mesh
        print_status "✓ Mesh configuration applied"
    else
        print_error "Mesh configuration not found"
        exit 1
    fi
    
    # Copy cluster environment
    if [ -f "cluster.env" ]; then
        sudo cp cluster.env /var/lib/istio/envoy/
        sudo chmod 644 /var/lib/istio/envoy/cluster.env
        print_status "✓ Cluster environment configured"
    else
        print_error "Cluster environment not found"
        exit 1
    fi

    # Copy cluster environment
    if [ -f "hosts" ]; then
        sudo cat hosts >> /etc/hosts
        print_status "✓ Cluster hosts configured"
    else
        print_error "Cluster hosts not found"
        exit 1
    fi

    sudo chown -R istio-proxy /var/lib/istio \
        /etc/certs \
        /etc/istio/proxy \
        /etc/istio/config \
        /var/run/secrets \
        /etc/certs/root-cert.pem

    print_status "✓ Istio workload integration components configured"
}

# Create sample web service (the actual workload)
create_sample_service() {
    print_status "Creating VM web service workload..."
    
    # Create service directory
    mkdir -p /home/azureuser/vm-service
    
    # Create enhanced Python web service
    cat > /home/azureuser/vm-service/app.py <<'PYEOF'
#!/usr/bin/env python3
from flask import Flask, jsonify, request
import socket
import os
import json
from datetime import datetime

app = Flask(__name__)

@app.route('/health')
def health_check():
    """Health check endpoint for load balancer probes"""
    return jsonify({
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "hostname": socket.gethostname(),
        "service": "vm-web-service",
        "version": "v1.0",
        "location": "Azure VM in Istio Mesh"
    })

@app.route('/info')
def service_info():
    """Service information endpoint"""
    headers = dict(request.headers)
    return jsonify({
        "service": "vm-web-service",
        "version": "v1.0",
        "hostname": socket.gethostname(),
        "environment": "istio-mesh",
        "platform": "Azure VM",
        "timestamp": datetime.now().isoformat(),
        "request_headers": headers,
        "client_ip": request.remote_addr
    })

@app.route('/vm-api/status')
def vm_status():
    """VM-specific status endpoint"""
    return jsonify({
        "vm_status": "running",
        "service_type": "istio_workload",
        "mesh_integration": "enabled",
        "hostname": socket.gethostname(),
        "timestamp": datetime.now().isoformat()
    })

@app.route('/')
def index():
    """Main service page"""
    return f"""
    <html>
    <head>
        <title>VM Web Service - Istio Mesh</title>
        <style>
            body {{ font-family: Arial, sans-serif; margin: 40px; }}
            .header {{ background-color: #f0f0f0; padding: 20px; border-radius: 5px; }}
            .info {{ margin: 20px 0; }}
            .endpoint {{ background-color: #e8f4f8; padding: 10px; margin: 5px; border-radius: 3px; }}
        </style>
    </head>
    <body>
        <div class="header">
            <h1>VM Web Service</h1>
            <p><strong>Istio Mesh Workload</strong></p>
        </div>
        
        <div class="info">
            <p><strong>Service:</strong> vm-web-service</p>
            <p><strong>Version:</strong> v1.0</p>
            <p><strong>Hostname:</strong> {socket.gethostname()}</p>
            <p><strong>Platform:</strong> Azure VM in Istio Service Mesh</p>
            <p><strong>Time:</strong> {datetime.now().isoformat()}</p>
        </div>
        
        <h3>Available Endpoints:</h3>
        <div class="endpoint"><a href="/health">Health Check</a> - Service health status</div>
        <div class="endpoint"><a href="/info">Service Info</a> - Detailed service information</div>
        <div class="endpoint"><a href="/vm-api/status">VM Status</a> - VM-specific status</div>
        
        <hr>
        <p><em>This service is part of the Istio service mesh and can communicate with other services in the cluster.</em></p>
    </body>
    </html>
    """

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)
PYEOF

    chmod +x /home/azureuser/vm-service/app.py

    # Create systemd service for the workload
    sudo tee /etc/systemd/system/vm-web-service.service > /dev/null <<SERVICEEOF
[Unit]
Description=VM Web Service for Istio Mesh
Documentation=https://flask.palletsprojects.com/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=azureuser
Group=azureuser
WorkingDirectory=/home/azureuser/vm-service
ExecStart=/usr/bin/python3 /home/azureuser/vm-service/app.py
Restart=always
RestartSec=10
Environment=FLASK_ENV=production
Environment=PYTHONPATH=/home/azureuser/.local/lib/python3.10/site-packages
KillMode=mixed
TimeoutStartSec=30
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
SERVICEEOF

    # Reload systemd and enable the service
    sudo systemctl daemon-reload
    sudo systemctl enable vm-web-service.service
    
    print_status "✓ VM web service configuration created"
}

# Configure networking for mesh integration
configure_networking() {
    print_status "Configuring networking for Istio mesh integration..."
    
    # Configure UFW firewall rules for Azure VM
    sudo ufw --force enable
    sudo ufw allow 8080/tcp comment 'VM web service'
    sudo ufw allow 22/tcp comment 'SSH management'
    sudo ufw allow 15000:15090/tcp comment 'Istio sidecar ports'
    sudo ufw allow out 15012/tcp comment 'Istio discovery'
    
    print_status "✓ Networking configured for mesh workload"
}

# Configure basic monitoring for the workload
setup_monitoring() {
    print_status "Setting up basic workload monitoring..."
    
    # Create comprehensive health check script
    cat > /home/azureuser/check-service.sh <<'CHECKEOF'
#!/bin/bash
# Comprehensive health check script for VM service and Istio

print_status() {
    echo -e "\033[0;32m[INFO]\033[0m $1"
}

print_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1"
}

print_warning() {
    echo -e "\033[1;33m[WARNING]\033[0m $1"
}

# Check VM web service
SERVICE_URL="http://localhost:8080/health"
print_status "Checking VM web service..."

RESPONSE=$(curl -s --connect-timeout 5 $SERVICE_URL 2>/dev/null || echo "failed")

if echo "$RESPONSE" | grep -q "healthy"; then
    print_status "✓ VM web service is healthy"
    SERVICE_STATUS=0
else
    print_error "✗ VM web service is not responding"
    SERVICE_STATUS=1
fi

# Check Istio service
print_status "Checking Istio service..."

if sudo systemctl is-active --quiet istio; then
    print_status "✓ Istio service is running"
    ISTIO_STATUS=0
else
    print_error "✗ Istio service is not running"
    ISTIO_STATUS=1
fi

# Check Istio admin endpoint
print_status "Checking Istio admin interface..."

ISTIO_ADMIN=$(curl -s --connect-timeout 5 http://localhost:15000/stats/prometheus 2>/dev/null | head -n 1)

if [ -n "$ISTIO_ADMIN" ]; then
    print_status "✓ Istio admin interface is accessible"
    ADMIN_STATUS=0
else
    print_warning "⚠ Istio admin interface is not accessible"
    ADMIN_STATUS=1
fi

# Summary
echo ""
echo "=== Health Check Summary ==="
echo "VM Web Service: $([ $SERVICE_STATUS -eq 0 ] && echo "✓ Healthy" || echo "✗ Unhealthy")"
echo "Istio: $([ $ISTIO_STATUS -eq 0 ] && echo "✓ Running" || echo "✗ Stopped")"
echo "Istio Admin: $([ $ADMIN_STATUS -eq 0 ] && echo "✓ Available" || echo "⚠ Unavailable")"

# Exit with appropriate code
if [ $SERVICE_STATUS -eq 0 ] && [ $ISTIO_STATUS -eq 0 ]; then
    exit 0
else
    exit 1
fi
CHECKEOF

    chmod +x /home/azureuser/check-service.sh
    
    # Create service status script
    cat > /home/azureuser/service-status.sh <<'STATUSEOF'
#!/bin/bash
# Show detailed status of all services

echo "=== VM Services Status ==="
echo ""

echo "VM Web Service:"
sudo systemctl status vm-web-service.service --no-pager -l

echo ""
echo "Istio Service:"
sudo systemctl status istio.service --no-pager -l

echo ""
echo "Service Logs (last 10 lines):"
echo "--- VM Web Service ---"
sudo journalctl -u vm-web-service.service -n 10 --no-pager

echo ""
echo "--- Istio ---"
sudo journalctl -u istio.service -n 10 --no-pager
STATUSEOF

    chmod +x /home/azureuser/service-status.sh
    
    print_status "✓ Monitoring scripts configured"
}

# Start services in proper order with better error handling
start_services() {
    print_status "Starting services in proper order..."
    
    # Start VM web service first
    print_status "Starting VM web service..."
    sudo systemctl start vm-web-service.service
    
    # Wait for web service to be ready
    print_status "Waiting for VM web service to be ready..."
    for i in {1..30}; do
        if curl -s --connect-timeout 5 http://localhost:8080/health &>/dev/null; then
            print_status "✓ VM web service is ready"
            break
        fi
        if [ $i -eq 30 ]; then
            print_error "VM web service failed to start or become ready"
            sudo systemctl status vm-web-service.service
            sudo journalctl -u vm-web-service.service -n 20 --no-pager
            exit 1
        fi
        sleep 2
    done
    
    # Now start Istio
    print_status "Starting Istio..."
    sudo systemctl start istio.service
    
    # Wait for Istio to be ready
    print_status "Waiting for Istio to be ready..."
    sleep 15
    
    # Verify both services are running
    if sudo systemctl is-active --quiet vm-web-service; then
        print_status "✓ VM web service is running"
    else
        print_error "✗ VM web service failed to start"
        sudo systemctl status vm-web-service.service
    fi
    
    if sudo systemctl is-active --quiet istio; then
        print_status "✓ Istio is running"
    else
        print_warning "⚠ Istio may be starting up or failed to start"
        print_status "Checking Istio logs..."
        sudo journalctl -u istio.service -n 20 --no-pager
    fi
}

# Main execution
main() {
    print_status "Setting up VM as Istio mesh workload..."

    validate_prerequisites
    install_packages
    install_istio_certificates
    install_istio
    install_istio_components
    create_sample_service
    configure_networking
    setup_monitoring
    start_services
    
    print_status ""
    print_status "================================="
    print_status "VM mesh workload setup completed!"
    print_status "================================="
    print_status ""
    print_status "Service Information:"
    print_status "  VM Web Service: http://localhost:8080"
    print_status "  Health Check: http://localhost:8080/health"
    print_status "  Service Info: http://localhost:8080/info"
    print_status ""
    print_status "Management Commands:"
    print_status "  Check services: ./check-service.sh"
    print_status "  Service status: ./service-status.sh"
    print_status "  VM service: sudo systemctl status vm-web-service"
    print_status "  Istio: sudo systemctl status istio"
    print_status ""
    print_status "Logs:"
    print_status "  VM service logs: sudo journalctl -u vm-web-service -f"
    print_status "  Istio logs: sudo journalctl -u istio -f"
    print_status ""
    
    # Run final health check
    print_status "Running final health check..."
    if ./check-service.sh; then
        print_status "✓ All services are healthy and ready!"
    else
        print_warning "⚠ Some services may need attention. Check logs for details."
    fi
}

# Run main function
main "$@"
