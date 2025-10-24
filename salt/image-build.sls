# Salt State File for VM Image Building (Execute Once)
# This file is executed during the VM image creation process

# Update package cache and upgrade packages
update_packages:
  pkg.uptodate:
    - refresh: True

# Install required packages for Istio mesh integration
required_packages:
  pkg.installed:
    - pkgs:
      - curl
      - iptables
      - wget
      - systemd
      - unzip
      - ufw
      - python3
      - python3-pip

# Create necessary directories for Istio
create_istio_directories:
  file.directory:
    - names:
      - /etc/certs
      - /var/run/secrets/tokens
      - /var/run/secrets/istio/
      - /etc/istio/proxy
      - /etc/istio/config
      - /var/lib/istio/envoy
      - /etc/istio
      - /home/azureuser/istio-vm-setup
    - user: root
    - group: root
    - mode: 755
    - makedirs: True

# Set ownership for azureuser home directory
set_azureuser_directory_ownership:
  file.directory:
    - name: /home/azureuser/istio-vm-setup
    - user: azureuser
    - group: azureuser
    - mode: 755
    - makedirs: True

# Create health check script
health_check_script:
  file.managed:
    - name: /home/azureuser/check-service.sh
    - user: azureuser
    - group: azureuser
    - mode: 755
    - contents: |
        #!/bin/bash
        # Comprehensive health check script for Istio

        print_status() {
            echo -e "\033[0;32m[INFO]\033[0m $1"
        }

        print_error() {
            echo -e "\033[0;31m[ERROR]\033[0m $1"
        }

        print_warning() {
            echo -e "\033[1;33m[WARNING]\033[0m $1"
        }

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
        echo "Istio: $([ $ISTIO_STATUS -eq 0 ] && echo "✓ Running" || echo "✗ Stopped")"
        echo "Istio Admin: $([ $ADMIN_STATUS -eq 0 ] && echo "✓ Available" || echo "⚠ Unavailable")"

        # Exit with appropriate code
        if [ $ISTIO_STATUS -eq 0 ]; then
            exit 0
        else
            exit 1
        fi

# Create service status script
service_status_script:
  file.managed:
    - name: /home/azureuser/service-status.sh
    - user: azureuser
    - group: azureuser
    - mode: 755
    - contents: |
        #!/bin/bash
        # Show detailed status of Istio services

        echo "=== Istio Services Status ==="
        echo ""

        echo "Istio Service:"
        sudo systemctl status istio.service --no-pager -l

        echo ""
        echo "Service Logs (last 10 lines):"
        echo "--- Istio ---"
        sudo journalctl -u istio.service -n 10 --no-pager

# Create Istio installation script
istio_installation_script:
  file.managed:
    - name: /home/azureuser/install-istio.sh
    - user: azureuser
    - group: azureuser
    - mode: 755
    - contents: |
        #!/bin/bash
        # Install Istio sidecar components

        set -e

        print_status() {
            echo -e "\033[0;32m[INFO]\033[0m $1"
        }

        print_error() {
            echo -e "\033[0;31m[ERROR]\033[0m $1"
        }

        ISTIO_VERSION="1.27.0"
        DOWNLOAD_DIR="/tmp/istio-download"

        # Check if pilot-agent is already installed
        if [ -f "/usr/local/bin/pilot-agent" ]; then
            print_status "✓ Istio already installed"
            if /usr/local/bin/pilot-agent version &>/dev/null; then
                print_status "✓ Pilot agent installation verified"
                exit 0
            else
                print_status "Existing pilot-agent installation appears corrupted, reinstalling..."
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
            exit 1
        fi

        # Verify download
        if [ ! -f "istio-sidecar.deb" ]; then
            print_error "Istio download file not found after download"
            exit 1
        fi

        print_status "Installing Istio..."

        # Installing with proper error handling
        if ! sudo dpkg -i istio-sidecar.deb; then
            print_error "Failed to install Istio package"
            exit 1
        fi

        # Verify installation
        if /usr/local/bin/pilot-agent version &>/dev/null; then
            print_status "✓ Istio installed successfully"
        else
            print_error "Pilot agent installation verification failed"
            exit 1
        fi

        # Cleanup download directory
        cd /home/azureuser
        rm -rf "$DOWNLOAD_DIR"

        print_status "✓ Istio installation completed"

# Create VM mesh setup completion script
mesh_setup_completion_script:
  file.managed:
    - name: /home/azureuser/complete-mesh-setup.sh
    - user: azureuser
    - group: azureuser
    - mode: 755
    - contents: |
        #!/bin/bash
        # Complete the mesh setup after certificates are received

        set -e

        print_status() {
            echo -e "\033[0;32m[INFO]\033[0m $1"
        }

        print_error() {
            echo -e "\033[0;31m[ERROR]\033[0m $1"
        }

        print_warning() {
            echo -e "\033[1;33m[WARNING]\033[0m $1"
        }

        # Check if required files exist
        if [ ! -d "/tmp/vm-files" ]; then
            print_error "VM files directory not found. Please ensure certificates and configuration files are transferred."
            exit 1
        fi

        # Validate required files
        required_files=("istio-token" "root-cert.pem" "cluster.env" "mesh.yaml" "hosts")
        for file in "${required_files[@]}"; do
            if [ ! -f "/tmp/vm-files/$file" ]; then
                print_error "Required file not found: $file"
                exit 1
            fi
        done

        print_status "Installing Istio certificates and configuration..."

        # Copy certificates
        sudo cp /tmp/vm-files/root-cert.pem /etc/certs/
        sudo chmod 644 /etc/certs/root-cert.pem
        sudo cp /etc/certs/root-cert.pem /var/run/secrets/istio/

        # Copy Istio token
        sudo cp /tmp/vm-files/istio-token /var/run/secrets/tokens/istio-token
        sudo chmod 644 /var/run/secrets/tokens/istio-token

        # Update hosts file
        sudo sh -c "cat /tmp/vm-files/hosts >> /etc/hosts"
        sudo sh -c "echo '127.0.0.1 istio-vm' >> /etc/hosts"

        # Copy mesh configuration
        sudo cp /tmp/vm-files/mesh.yaml /etc/istio/config/mesh
        sudo chmod 644 /etc/istio/config/mesh

        # Copy cluster environment
        sudo cp /tmp/vm-files/cluster.env /var/lib/istio/envoy/
        sudo chmod 644 /var/lib/istio/envoy/cluster.env

        # Set proper ownership
        sudo chown -R istio-proxy:istio-proxy /etc/certs /var/run/secrets /var/lib/istio /etc/istio/proxy /etc/istio/config

        print_status "Starting Istio services..."

        # Start Istio
        sudo systemctl start istio.service
        sleep 15

        print_status "✓ Mesh setup completed successfully!"
        print_status "Run ./check-service.sh to verify Istio is healthy"

# Install Istio during image build
install_istio_during_build:
  cmd.run:
    - name: /home/azureuser/install-istio.sh
    - user: azureuser
    - cwd: /home/azureuser
    - require:
      - file: istio_installation_script
      - pkg: required_packages

# Configure UFW firewall
configure_ufw_firewall:
  cmd.run:
    - names:
      - ufw --force enable
      - ufw allow 22/tcp comment 'SSH management'
      - ufw allow 15000:15090/tcp comment 'Istio sidecar ports'
      - ufw allow out 15012/tcp comment 'Istio discovery'
    - require:
      - pkg: required_packages

# Reload systemd daemon
reload_systemd:
  cmd.run:
    - name: systemctl daemon-reload
    - require:
      - cmd: install_istio_during_build

# Set final ownership for azureuser files
final_ownership_setup:
  cmd.run:
    - name: chown -R azureuser:azureuser /home/azureuser/
    - require:
      - file: health_check_script
      - file: service_status_script
      - file: istio_installation_script
      - file: mesh_setup_completion_script

# Create a marker file to indicate image build completion
image_build_marker:
  file.managed:
    - name: /etc/istio-image-build-complete
    - contents: |
        # This file indicates that the Istio VM image build process has completed
        # Build timestamp: {{ salt['cmd.run']('date') }}
        # Salt execution ID: {{ salt['grains.get']('id') }}
    - user: root
    - group: root
    - mode: 644
    - require:
      - cmd: final_ownership_setup
      - cmd: reload_systemd
      - cmd: configure_ufw_firewall