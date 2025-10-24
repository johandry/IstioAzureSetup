# Salt State File for Boot-Time Execution
# This file is executed every time the VM boots up

# Check if image build process was completed
check_image_build_completion:
  cmd.run:
    - name: test -f /etc/istio-image-build-complete
    - failhard: True
    - onlyif: test ! -f /etc/istio-image-build-complete

# Log boot-time execution
log_boot_execution:
  file.append:
    - name: /var/log/istio-boot.log
    - text: |
        ========================================
        Istio Boot-Time Configuration Started
        Timestamp: {{ salt['cmd.run']('date') }}
        Host: {{ grains['id'] }}
        ========================================

# Ensure Istio directories have correct permissions at boot
verify_istio_directories:
  file.directory:
    - names:
      - /etc/certs
      - /var/run/secrets/tokens
      - /var/run/secrets/istio/
      - /etc/istio/proxy
      - /etc/istio/config
      - /var/lib/istio/envoy
      - /etc/istio
    - user: root
    - group: root
    - mode: 755
    - makedirs: True

# Ensure azureuser scripts have correct permissions
verify_script_permissions:
  file.managed:
    - names:
      - /home/azureuser/check-service.sh:
        - user: azureuser
        - group: azureuser
        - mode: 755
      - /home/azureuser/service-status.sh:
        - user: azureuser
        - group: azureuser
        - mode: 755
      - /home/azureuser/install-istio.sh:
        - user: azureuser
        - group: azureuser
        - mode: 755
      - /home/azureuser/complete-mesh-setup.sh:
        - user: azureuser
        - group: azureuser
        - mode: 755

# Check if VM files directory exists and contains certificates
check_vm_files_directory:
  cmd.run:
    - name: |
        if [ -d "/tmp/vm-files" ] && [ -f "/tmp/vm-files/istio-token" ]; then
          echo "VM files detected, proceeding with mesh setup"
          exit 0
        else
          echo "VM files not found, skipping automatic mesh setup"
          exit 1
        fi
    - success_retcodes: [0, 1]

# Automatically complete mesh setup if certificates are available
auto_complete_mesh_setup:
  cmd.run:
    - name: /home/azureuser/complete-mesh-setup.sh
    - user: azureuser
    - cwd: /home/azureuser
    - onlyif: test -d /tmp/vm-files && test -f /tmp/vm-files/istio-token
    - require:
      - cmd: check_vm_files_directory

# Ensure UFW firewall rules are active
ensure_firewall_rules:
  cmd.run:
    - names:
      - ufw --force enable || true
      - ufw allow 22/tcp comment 'SSH management' || true
      - ufw allow 15000:15090/tcp comment 'Istio sidecar ports' || true
      - ufw allow out 15012/tcp comment 'Istio discovery' || true

# Check network connectivity to Istio control plane
check_network_connectivity:
  cmd.run:
    - name: |
        # Check if cluster.env exists and extract discovery address
        if [ -f "/var/lib/istio/envoy/cluster.env" ]; then
          PILOT_ADDRESS=$(grep PILOT_ADDRESS /var/lib/istio/envoy/cluster.env | cut -d'=' -f2)
          if [ -n "$PILOT_ADDRESS" ]; then
            echo "Testing connectivity to Istio control plane: $PILOT_ADDRESS"
            # Try to connect to the control plane (port 15010 or 15011)
            timeout 10 bash -c "</dev/tcp/${PILOT_ADDRESS}/15010" 2>/dev/null && echo "✓ Control plane reachable" || echo "⚠ Control plane not reachable"
          fi
        else
          echo "⚠ Cluster configuration not found"
        fi
    - success_retcodes: [0, 1]
    - onlyif: test -f /var/lib/istio/envoy/cluster.env

# Start or restart Istio service if it's not running
ensure_istio_service_running:
  service.running:
    - name: istio
    - enable: True
    - restart: True
    - onlyif: test -f /etc/istio/config/mesh && test -f /var/run/secrets/tokens/istio-token

# Wait for Istio service to be ready
wait_for_istio_ready:
  cmd.run:
    - name: |
        echo "Waiting for Istio to be ready..."
        for i in {1..30}; do
          if curl -s --connect-timeout 2 http://localhost:15000/ready >/dev/null 2>&1; then
            echo "✓ Istio is ready"
            exit 0
          fi
          echo "Waiting... ($i/30)"
          sleep 2
        done
        echo "⚠ Istio readiness check timed out"
        exit 1
    - success_retcodes: [0, 1]
    - require:
      - service: ensure_istio_service_running
    - onlyif: systemctl is-active --quiet istio

# Perform health check
perform_boot_health_check:
  cmd.run:
    - name: /home/azureuser/check-service.sh
    - user: azureuser
    - cwd: /home/azureuser
    - success_retcodes: [0, 1]
    - require:
      - cmd: wait_for_istio_ready

# Create boot completion marker with timestamp
create_boot_marker:
  file.managed:
    - name: /tmp/istio-boot-complete
    - contents: |
        # Boot-time configuration completed
        Timestamp: {{ salt['cmd.run']('date') }}
        Host: {{ grains['id'] }}
        Istio Status: {{ salt['cmd.run']('systemctl is-active istio || echo "inactive"') }}
    - user: root
    - group: root
    - mode: 644

# Log completion status
log_boot_completion:
  file.append:
    - name: /var/log/istio-boot.log
    - text: |
        ========================================
        Istio Boot-Time Configuration Completed
        Timestamp: {{ salt['cmd.run']('date') }}
        Status: {{ salt['cmd.run']('systemctl is-active istio 2>/dev/null || echo "service not active"') }}
        ========================================
    - require:
      - file: create_boot_marker

# Clean up old boot markers (keep only the last 10)
cleanup_old_markers:
  cmd.run:
    - name: |
        find /tmp -name "istio-boot-complete*" -type f | head -n -10 | xargs -r rm -f
    - success_retcodes: [0, 1]
    - require:
      - file: log_boot_completion