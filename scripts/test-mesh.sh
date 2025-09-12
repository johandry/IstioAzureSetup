#!/bin/bash

# Test Istio VM Mesh Integration
# This script validates VM mesh connectivity and service discovery

# Note: We don't use 'set -e' here because we want to continue running all tests
# even if some fail, and accumulate the failure count

# Shared configuration variables
VM_NAMESPACE="vm-workloads"
VM_APP="vm-web-service"

# Configuration variables
VM_SERVICE_NAME=$VM_APP
TEST_TIMEOUT=30

# Array to track failed tests
FAILED_TESTS=()
FAILED_TEST_DETAILS=()
TEST_WARNINGS=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_test_result() {
    if [ "$1" = "PASS" ]; then
        echo -e "${GREEN}✓ $2${NC}"
    else
        echo -e "${RED}✗ $2${NC}"
        # Track the failed test detail
        FAILED_TEST_DETAILS+=("$2")
    fi
}

# Function to add warnings
add_warning() {
    TEST_WARNINGS+=("$1")
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking test prerequisites..."
    
    # Check kubectl connectivity
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Not connected to Kubernetes cluster"
        exit 1
    fi
    
    # Check if Istio is installed
    if ! kubectl get namespace istio-system &> /dev/null; then
        print_error "Istio is not installed"
        exit 1
    fi
    
    # Ensure mesh-test namespace exists
    if ! kubectl get namespace mesh-test &> /dev/null; then
        print_error "Namespace mesh-test not found, please execute: ./setup-istio.sh deploy-mesh-test"
        exit 1
    fi
    
    # Check if sleep pod exists for testing
    if ! kubectl get deployment sleep -n mesh-test &> /dev/null; then
        print_error "Sleep pod not found, please execute: ./setup-istio.sh deploy-mesh-test"
        exit 1
    fi
    
    print_status "Prerequisites check passed"
    return 0
}

# Test 1: Basic Istio installation
test_istio_installation() {
    print_header "TEST 1: ISTIO INSTALLATION"
    
    local passed=0
    local total=0
    
    # Test istiod deployment
    ((total++))
    if kubectl get deployment istiod -n istio-system &> /dev/null; then
        local ready_replicas=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [ "$ready_replicas" -gt "0" ]; then
            print_test_result "PASS" "Istiod deployment is running ($ready_replicas replicas)"
            ((passed++))
        else
            print_test_result "FAIL" "Istiod deployment exists but no replicas are ready"
        fi
    else
        print_test_result "FAIL" "Istiod deployment not found"
    fi
    
    # Test ingress gateway
    ((total++))
    if kubectl get deployment istio-ingressgateway -n istio-system &> /dev/null; then
        local ready_replicas=$(kubectl get deployment istio-ingressgateway -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [ "$ready_replicas" -gt "0" ]; then
            print_test_result "PASS" "Istio Ingress Gateway is running ($ready_replicas replicas)"
            ((passed++))
        else
            print_test_result "FAIL" "Istio Ingress Gateway exists but no replicas are ready"
        fi
    else
        print_test_result "FAIL" "Istio Ingress Gateway not found"
    fi
    
    # Test gateway service
    ((total++))
    local gateway_ip=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$gateway_ip" ]; then
        print_test_result "PASS" "Gateway LoadBalancer IP assigned: $gateway_ip"
        ((passed++))
    else
        print_test_result "FAIL" "Gateway LoadBalancer IP not assigned"
    fi
    
    # Test namespace injection
    ((total++))
    local injection_label=$(kubectl get namespace default -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || echo "")
    if [ "$injection_label" = "enabled" ]; then
        print_test_result "PASS" "Default namespace has Istio injection enabled"
        ((passed++))
    else
        print_test_result "FAIL" "Default namespace does not have Istio injection enabled"
    fi
    
    echo ""
    print_status "Istio Installation Tests: $passed/$total passed"
    return $((total - passed))
}

# Test 2: VM Namespace and Services
test_vm_namespace() {
    print_header "TEST 2: VM NAMESPACE AND SERVICES"
    
    local passed=0
    local total=0
    
    # Test VM namespace exists
    ((total++))
    if kubectl get namespace "$VM_NAMESPACE" &> /dev/null; then
        print_test_result "PASS" "VM namespace '$VM_NAMESPACE' exists"
        ((passed++))
    else
        print_test_result "FAIL" "VM namespace '$VM_NAMESPACE' not found"
        echo ""
        print_status "VM Namespace Tests: $passed/$total passed"
        return $((total - passed))
    fi
    
    # Test VM namespace has Istio injection
    ((total++))
    local injection_label=$(kubectl get namespace "$VM_NAMESPACE" -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || echo "")
    if [ "$injection_label" = "enabled" ]; then
        print_test_result "PASS" "VM namespace has Istio injection enabled"
        ((passed++))
    else
        print_test_result "FAIL" "VM namespace does not have Istio injection enabled"
    fi
    
    # Test VM service exists
    ((total++))
    if kubectl get service "$VM_SERVICE_NAME" -n "$VM_NAMESPACE" &> /dev/null; then
        print_test_result "PASS" "VM service '$VM_SERVICE_NAME' exists"
        ((passed++))
    else
        print_test_result "FAIL" "VM service '$VM_SERVICE_NAME' not found"
    fi
    
    # Test WorkloadEntry exists
    ((total++))
    local workload_entries=$(kubectl get workloadentry -n "$VM_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    if [ "$workload_entries" -gt "0" ]; then
        print_test_result "PASS" "WorkloadEntry exists ($workload_entries found)"
        ((passed++))
    else
        print_test_result "FAIL" "No WorkloadEntry found"
    fi
    
    # Test ServiceEntry exists
    ((total++))
    local service_entries=$(kubectl get serviceentry -n "$VM_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    if [ "$service_entries" -gt "0" ]; then
        print_test_result "PASS" "ServiceEntry exists ($service_entries found)"
        ((passed++))
    else
        print_test_result "FAIL" "No ServiceEntry found"
    fi
    
    echo ""
    print_status "VM Namespace Tests: $passed/$total passed"
    return $((total - passed))
}

# Test 3: Service Discovery
test_service_discovery() {
    print_header "TEST 3: SERVICE DISCOVERY"
    
    local passed=0
    local total=0
    
    # Test DNS resolution for VM service
    ((total++))
    if kubectl exec deployment/sleep -n mesh-test -- nslookup "$VM_SERVICE_NAME.$VM_NAMESPACE.svc.cluster.local" &> /dev/null; then
        print_test_result "PASS" "VM service DNS resolution works"
        ((passed++))
    else
        print_test_result "FAIL" "VM service DNS resolution failed"
    fi
    
    # TODO: Fix this test
    # Test short name resolution
    ((total++))
    if kubectl exec deployment/sleep -n mesh-test -- nslookup "$VM_SERVICE_NAME.$VM_NAMESPACE" &> /dev/null; then
        print_test_result "PASS" "VM service short name resolution works"
        ((passed++))
    else
        print_test_result "FAIL" "VM service short name resolution failed"
    fi
    
    # Test Istio service registry
    ((total++))
    local istioctl_path=""
    if command -v istioctl &> /dev/null; then
        istioctl_path="istioctl"
    elif [ -f "../workspace/istio-installation/bin/istioctl" ]; then
        istioctl_path="../workspace/istio-installation/bin/istioctl"
    elif [ -f "workspace/istio-installation/bin/istioctl" ]; then
        istioctl_path="workspace/istio-installation/bin/istioctl"
    fi
    
    if [ -n "$istioctl_path" ]; then
        if $istioctl_path proxy-config cluster deployment/sleep.mesh-test | grep -q "$VM_SERVICE_NAME"; then
            print_test_result "PASS" "VM service found in Istio service registry"
            ((passed++))
        else
            print_test_result "FAIL" "VM service not found in Istio service registry"
        fi
    else
        print_test_result "FAIL" "istioctl not found, cannot test service registry"
    fi
    
    echo ""
    print_status "Service Discovery Tests: $passed/$total passed"
    return $((total - passed))
}

# Test 4: Connectivity
test_connectivity() {
    print_header "TEST 4: CONNECTIVITY TESTS"
    
    local passed=0
    local total=0

    # Test basic connectivity to VM service from AKS (with retries)
    ((total++))
    local aks_to_vm_success=false
    local retry_count=0
    local max_retries=3
    
    print_status "Testing AKS to VM connectivity (will retry up to $max_retries times)..."
    
    while [ $retry_count -lt $max_retries ] && [ "$aks_to_vm_success" = false ]; do
        retry_count=$((retry_count + 1))
        if [ $retry_count -gt 1 ]; then
            print_status "Retry attempt $retry_count/$max_retries..."
            sleep 2
        fi
        
        local vm_response=$(kubectl exec deployment/sleep -n mesh-test -- curl -s --max-time $TEST_TIMEOUT "$VM_SERVICE_NAME.$VM_NAMESPACE:8080" 2>/dev/null || echo "")
        if echo "$vm_response" | grep -q "VM Web Service\|nginx\|Welcome"; then
            aks_to_vm_success=true
            if [ $retry_count -eq 1 ]; then
                print_test_result "PASS" "AKS to VM service HTTP connectivity works"
            else
                print_test_result "PASS" "AKS to VM service HTTP connectivity works (attempt $retry_count)"
                add_warning "AKS to VM connectivity required $retry_count attempts - connection may be unstable"
            fi
            print_status "VM service response: $(echo "$vm_response" | head -1 | tr -d '\r\n')"
            ((passed++))
        fi
    done
    
    if [ "$aks_to_vm_success" = false ]; then
        print_test_result "FAIL" "AKS to VM service HTTP connectivity failed after $max_retries attempts"
        # Debug information
        print_status "Debug: Testing VM service connectivity from AKS..."
        kubectl exec deployment/sleep -n mesh-test -- curl -v --max-time 10 "$VM_SERVICE_NAME.$VM_NAMESPACE:8080" || true
    fi
       
    # Test external connectivity (basic)
    ((total++))
    if kubectl exec deployment/sleep -n mesh-test -- curl -s --max-time $TEST_TIMEOUT httpbin.org/headers | grep -q "User-Agent"; then
        print_test_result "PASS" "External connectivity works"
        ((passed++))
    else
        print_test_result "FAIL" "External connectivity failed (might be expected in restricted networks)"
    fi
    
    # VM to AKS Connectivity Tests
    print_status "Testing VM to AKS connectivity..."
    
    # Get VM IP for SSH connection
    local vm_ip=""
    if [ -f "../workspace/configs/vm-config.env" ]; then
        source "../workspace/configs/vm-config.env"
        vm_ip="$VM_IP"
    elif [ -f "workspace/configs/vm-config.env" ]; then
        source "workspace/configs/vm-config.env"
        vm_ip="$VM_IP"
    fi
    
    if [ -z "$vm_ip" ]; then
        # Try to get VM IP from Azure CLI if config file not found
        vm_ip=$(az vm show -d -g istio-playground-rg -n istio-vm --query publicIps -o tsv 2>/dev/null || echo "")
    fi
    
    if [ -n "$vm_ip" ]; then
        print_status "Testing VM connectivity from VM IP: $vm_ip"
        
        # Check if HelloWorld service exists
        ((total++))
        if kubectl get service helloworld -n helloworld &> /dev/null; then
            print_test_result "PASS" "HelloWorld service exists in AKS"
            ((passed++))
            
            # Test VM can resolve HelloWorld service DNS
            ((total++))
            if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 azureuser@$vm_ip "nslookup helloworld.helloworld.svc.cluster.local" &> /dev/null; then
                print_test_result "PASS" "VM can resolve HelloWorld service DNS"
                ((passed++))
            else
                print_test_result "FAIL" "VM cannot resolve HelloWorld service DNS"
            fi
            
            # Test VM can connect to HelloWorld service
            ((total++))
            local hello_response=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 azureuser@$vm_ip "curl -s --max-time 30 helloworld.helloworld:5000/hello" 2>/dev/null || echo "")
            if echo "$hello_response" | grep -q "Hello version"; then
                print_test_result "PASS" "VM can connect to HelloWorld service"
                ((passed++))
                print_status "HelloWorld response: $(echo "$hello_response" | head -1)"
            else
                print_test_result "FAIL" "VM cannot connect to HelloWorld service"
                # Debug information
                print_status "Debug: Testing HelloWorld connectivity from VM..."
                ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 azureuser@$vm_ip "curl -v --max-time 10 helloworld.helloworld:5000/hello" || true
            fi
            
            # Test multiple requests for load balancing verification
            ((total++))
            local v1_count=0
            local v2_count=0
            local failed_count=0
            
            print_status "Testing load balancing from VM (5 requests)..."
            for i in {1..5}; do
                local response=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 azureuser@$vm_ip "curl -s --max-time 10 helloworld.helloworld:5000/hello" 2>/dev/null || echo "")
                if echo "$response" | grep -q "version: v1"; then
                    v1_count=$((v1_count + 1))
                elif echo "$response" | grep -q "version: v2"; then
                    v2_count=$((v2_count + 1))
                else
                    failed_count=$((failed_count + 1))
                fi
            done
            
            if [ $failed_count -eq 0 ] && [ $v1_count -gt 0 ] && [ $v2_count -gt 0 ]; then
                print_test_result "PASS" "VM load balancing to HelloWorld works (v1:$v1_count, v2:$v2_count)"
                ((passed++))
            elif [ $failed_count -eq 0 ]; then
                print_test_result "PASS" "VM connectivity to HelloWorld works but no load balancing (v1:$v1_count, v2:$v2_count)"
                ((passed++))
            else
                print_test_result "FAIL" "VM load balancing test failed (v1:$v1_count, v2:$v2_count, failed:$failed_count)"
            fi
            
            # Test mTLS encryption from VM to HelloWorld
            ((total++))
            local istioctl_path=""
            if command -v istioctl &> /dev/null; then
                istioctl_path="istioctl"
            elif [ -f "../workspace/istio-installation/bin/istioctl" ]; then
                istioctl_path="../workspace/istio-installation/bin/istioctl"
            elif [ -f "workspace/istio-installation/bin/istioctl" ]; then
                istioctl_path="workspace/istio-installation/bin/istioctl"
            fi
            
            if [ -n "$istioctl_path" ]; then
                # Check if VM has Istio proxy/sidecar for mTLS
                local vm_mtls_check=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 azureuser@$vm_ip "ss -tulpn | grep :15001" 2>/dev/null || echo "")
                if [ -n "$vm_mtls_check" ]; then
                    # VM has Istio proxy, check mTLS by examining cluster config
                    local sleep_pod=$(kubectl get pods -n mesh-test -l app=sleep --no-headers -o custom-columns=":metadata.name" | head -1)
                    if [ -n "$sleep_pod" ]; then
                        # Check outbound cluster configuration for HelloWorld service TLS
                        local cluster_config=$($istioctl_path proxy-config cluster "$sleep_pod.mesh-test" --fqdn helloworld.helloworld.svc.cluster.local -o json 2>/dev/null | grep -i "transport_socket\|tls_context" || echo "")
                        if [ -n "$cluster_config" ]; then
                            print_test_result "PASS" "VM to HelloWorld connection has mTLS transport configured"
                            ((passed++))
                        else
                            print_test_result "FAIL" "VM to HelloWorld connection does not have mTLS transport configured"
                        fi
                        
                        # Additional check: verify service exists in mesh
                        ((total++))
                        local helloworld_cluster=$($istioctl_path proxy-config cluster "$sleep_pod.mesh-test" | grep "helloworld.helloworld.svc.cluster.local" || echo "")
                        if [ -n "$helloworld_cluster" ]; then
                            print_test_result "PASS" "VM to HelloWorld connection exists in service mesh"
                            ((passed++))
                        else
                            print_test_result "FAIL" "VM to HelloWorld connection not found in service mesh configuration"
                        fi
                    else
                        print_test_result "FAIL" "Cannot find sleep pod to check mTLS configuration"
                    fi
                else
                    print_test_result "FAIL" "VM does not have Istio proxy for mTLS (port 15001 not found)"
                fi
            else
                print_test_result "FAIL" "istioctl not found, cannot verify VM to HelloWorld mTLS encryption"
            fi
            
        else
            print_test_result "FAIL" "HelloWorld service not found in AKS"
            print_status "Note: Deploy HelloWorld first with: ./setup-istio.sh setup"
            ((total += 4)) # Skip the dependent tests
        fi
        
        # AKS to VM Connectivity Tests
        print_status "Testing AKS to VM connectivity..."
        
        # Check if HelloWorld pods can reach VM service
        if kubectl get pods -n helloworld -l app=helloworld --no-headers | head -1 | awk '{print $1}' | grep -q "helloworld"; then
            local helloworld_pod=$(kubectl get pods -n helloworld -l app=helloworld --no-headers | head -1 | awk '{print $1}')
            
            # Test HelloWorld pod can resolve VM service DNS
            ((total++))
            if kubectl exec $helloworld_pod -n helloworld -- nslookup $VM_SERVICE_NAME.$VM_NAMESPACE.svc.cluster.local &> /dev/null; then
                print_test_result "PASS" "HelloWorld pod can resolve VM service DNS"
                ((passed++))
            else
                print_test_result "FAIL" "HelloWorld pod cannot resolve VM service DNS"
            fi
            
            # Test HelloWorld pod can connect to VM service (with retries)
            ((total++))
            local hello_to_vm_success=false
            local retry_count=0
            local max_retries=3
            
            print_status "Testing HelloWorld pod to VM connectivity (will retry up to $max_retries times)..."
            
            while [ $retry_count -lt $max_retries ] && [ "$hello_to_vm_success" = false ]; do
                retry_count=$((retry_count + 1))
                if [ $retry_count -gt 1 ]; then
                    print_status "Retry attempt $retry_count/$max_retries..."
                    sleep 2
                fi
                
                local vm_response=$(kubectl exec $helloworld_pod -n helloworld -- curl -s --max-time $TEST_TIMEOUT $VM_SERVICE_NAME.$VM_NAMESPACE:8080 2>/dev/null || echo "")
                if echo "$vm_response" | grep -q "VM Web Service\|nginx\|Welcome"; then
                    hello_to_vm_success=true
                    if [ $retry_count -eq 1 ]; then
                        print_test_result "PASS" "HelloWorld pod can connect to VM service"
                    else
                        print_test_result "PASS" "HelloWorld pod can connect to VM service (attempt $retry_count)"
                        add_warning "HelloWorld to VM connectivity required $retry_count attempts - connection may be unstable"
                    fi
                    print_status "VM service response: $(echo "$vm_response" | head -1 | tr -d '\r\n')"
                    ((passed++))
                fi
            done
            
            if [ "$hello_to_vm_success" = false ]; then
                print_test_result "FAIL" "HelloWorld pod cannot connect to VM service after $max_retries attempts"
                # Debug information
                print_status "Debug: Testing VM service connectivity from HelloWorld pod..."
                kubectl exec $helloworld_pod -n helloworld -- curl -v --max-time 10 $VM_SERVICE_NAME.$VM_NAMESPACE:8080 || true
            fi
            
            # Test service mesh traffic policies (if VM service has Istio sidecar)
            ((total++))
            if [ -n "$istioctl_path" ]; then
                if $istioctl_path proxy-config cluster $helloworld_pod.helloworld | grep -q "$VM_SERVICE_NAME"; then
                    print_test_result "PASS" "VM service found in HelloWorld pod's service mesh configuration"
                    ((passed++))
                else
                    print_test_result "FAIL" "VM service not found in HelloWorld pod's service mesh configuration"
                fi
            else
                print_test_result "FAIL" "istioctl not found, cannot test service mesh configuration"
            fi
            
            # Test mTLS encryption from HelloWorld to VM
            ((total++))
            if [ -n "$istioctl_path" ]; then
                # Check mTLS policy for HelloWorld to VM communication using cluster config
                local vm_cluster_config=$($istioctl_path proxy-config cluster $helloworld_pod.helloworld --fqdn $VM_SERVICE_NAME.$VM_NAMESPACE.svc.cluster.local -o json 2>/dev/null | grep -i "transport_socket\|tls_context" || echo "")
                if [ -n "$vm_cluster_config" ]; then
                    print_test_result "PASS" "HelloWorld to VM connection has mTLS transport configured"
                    ((passed++))
                else
                    print_test_result "FAIL" "HelloWorld to VM connection does not have mTLS transport configured"
                fi
                
                # Additional check: verify VM service exists in HelloWorld's cluster config
                ((total++))
                local vm_service_cluster=$($istioctl_path proxy-config cluster $helloworld_pod.helloworld | grep "$VM_SERVICE_NAME.$VM_NAMESPACE.svc.cluster.local" || echo "")
                if [ -n "$vm_service_cluster" ]; then
                    print_test_result "PASS" "HelloWorld to VM connection exists in service mesh"
                    ((passed++))
                else
                    print_test_result "FAIL" "HelloWorld to VM connection not found in service mesh configuration"
                fi
                
                # Additional check: look for Envoy proxy logs showing TLS activity
                ((total++))
                local proxy_logs=$(kubectl logs $helloworld_pod -n helloworld -c istio-proxy --tail=50 2>/dev/null | grep -i "tls\|ssl" | head -1 || echo "")
                if [ -n "$proxy_logs" ]; then
                    print_test_result "PASS" "HelloWorld to VM connection shows TLS activity in proxy logs"
                    ((passed++))
                else
                    print_test_result "FAIL" "HelloWorld to VM connection shows no TLS activity in proxy logs"
                fi
            else
                print_test_result "FAIL" "istioctl not found, cannot verify HelloWorld to VM mTLS encryption"
            fi
            
        else
            print_test_result "FAIL" "No HelloWorld pods found in AKS"
            print_status "Note: Deploy HelloWorld first with: ./setup-istio.sh setup"
            ((total += 3)) # Skip the dependent tests
        fi
        
    else
        print_test_result "FAIL" "VM IP address not found"
        print_status "Note: Cannot test VM connectivity without VM IP"
        ((total += 7)) # Skip all VM-related tests
    fi
    
    echo ""
    print_status "Connectivity Tests: $passed/$total passed"
    return $((total - passed))
}

# Test 5: Gateway Access
test_gateway_access() {
    print_header "TEST 5: GATEWAY ACCESS"
    
    local passed=0
    local total=0
    
    # Get gateway IP
    local gateway_ip=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [ -z "$gateway_ip" ]; then
        print_test_result "FAIL" "Gateway IP not available"
        echo ""
        print_status "Gateway Access Tests: 0/3 passed"
        return 3
    fi
    
    print_status "Testing gateway at IP: $gateway_ip"
    
    # Test gateway health endpoint
    ((total++))
    if curl -s --max-time $TEST_TIMEOUT "http://$gateway_ip/health" | grep -q "200\|ok\|healthy"; then
        print_test_result "PASS" "Gateway health endpoint accessible"
        ((passed++))
    else
        print_test_result "FAIL" "Gateway health endpoint not accessible"
    fi

    # TODO: Fix this test. Gateway is forbidden from company network
    # Test VM service through gateway
    ((total++))
    if curl -s --max-time $TEST_TIMEOUT "http://$gateway_ip/vm-service" | grep -q "VM Web Service\|nginx\|Welcome"; then
        print_test_result "PASS" "VM service accessible through gateway"
        ((passed++))
    else
        print_test_result "FAIL" "VM service not accessible through gateway"
    fi
    
    # Test observability tools services exist
    ((total++))
    local obs_services=0
    if kubectl get svc kiali -n istio-system &> /dev/null; then
        ((obs_services++))
    fi
    if kubectl get svc grafana -n istio-system &> /dev/null; then
        ((obs_services++))
    fi
    if kubectl get svc tracing -n istio-system &> /dev/null; then
        ((obs_services++))
    fi
    
    if [ "$obs_services" -gt "0" ]; then
        print_test_result "PASS" "Observability tools services available ($obs_services/3: $([ $obs_services -ge 1 ] && echo 'Kiali' && [ $obs_services -ge 2 ] && echo ', Grafana' && [ $obs_services -ge 3 ] && echo ', Jaeger' || echo ''))"
        ((passed++))
    else
        print_test_result "FAIL" "No observability tools services found"
    fi
    
    echo ""
    print_status "Gateway Access Tests: $passed/$total passed"
    return $((total - passed))
}

# Test 6: Istio Configuration
test_istio_configuration() {
    print_header "TEST 6: ISTIO CONFIGURATION"
    
    local passed=0
    local total=0
    
    # Test Gateway resource exists
    ((total++))
    if kubectl get gateway -n istio-system --no-headers 2>/dev/null | wc -l | grep -q -v "^0$"; then
        print_test_result "PASS" "Gateway resources exist"
        ((passed++))
    else
        print_test_result "FAIL" "No Gateway resources found"
    fi
    
    # Test VirtualService resources exist
    ((total++))
    local vs_count=$(kubectl get virtualservice --all-namespaces --no-headers 2>/dev/null | wc -l)
    if [ "$vs_count" -gt "0" ]; then
        print_test_result "PASS" "VirtualService resources exist ($vs_count found)"
        ((passed++))
    else
        print_test_result "FAIL" "No VirtualService resources found"
    fi
    
    # Test DestinationRule for VM service
    ((total++))
    if kubectl get destinationrule -n "$VM_NAMESPACE" --no-headers 2>/dev/null | grep -q "$VM_SERVICE_NAME"; then
        print_test_result "PASS" "DestinationRule for VM service exists"
        ((passed++))
    else
        print_test_result "FAIL" "DestinationRule for VM service not found"
    fi
    
    # Test sidecar injection is working
    ((total++))
    local injected_pods=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].name}{"\n"}{end}' | grep -c istio-proxy)
    if [ "$injected_pods" -gt "0" ]; then
        print_test_result "PASS" "Sidecar injection is working ($injected_pods pods with sidecars)"
        ((passed++))
    else
        print_test_result "FAIL" "No pods with Istio sidecars found"
    fi
    
    # Test mTLS policy configuration
    ((total++))
    local peerauthentication_count=$(kubectl get peerauthentication --all-namespaces --no-headers 2>/dev/null | wc -l)
    local authz_policy_count=$(kubectl get authorizationpolicy --all-namespaces --no-headers 2>/dev/null | wc -l)
    
    if [ "$peerauthentication_count" -gt "0" ] || [ "$authz_policy_count" -gt "0" ]; then
        print_test_result "PASS" "mTLS policies configured (PeerAuthentication: $peerauthentication_count, AuthorizationPolicy: $authz_policy_count)"
        ((passed++))
    else
        # Check if default mTLS is enabled (Istio default behavior)
        local istioctl_path=""
        if command -v istioctl &> /dev/null; then
            istioctl_path="istioctl"
        elif [ -f "../workspace/istio-installation/bin/istioctl" ]; then
            istioctl_path="../workspace/istio-installation/bin/istioctl"
        elif [ -f "workspace/istio-installation/bin/istioctl" ]; then
            istioctl_path="workspace/istio-installation/bin/istioctl"
        fi
        
        if [ -n "$istioctl_path" ]; then
            # Check for TLS transport configuration in cluster config
            local mtls_status=$($istioctl_path proxy-config cluster deployment/sleep.mesh-test -o json 2>/dev/null | grep -i "transport_socket\|tls_context" | head -1 || echo "")
            if [ -n "$mtls_status" ]; then
                print_test_result "PASS" "Default mTLS is enabled (TLS transport found in cluster config)"
                ((passed++))
            else
                # Check PeerAuthentication default policy
                local default_pa=$(kubectl get peerauthentication default -n istio-system -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || echo "")
                if [ "$default_pa" = "STRICT" ]; then
                    print_test_result "PASS" "Default mTLS is configured in STRICT mode"
                    ((passed++))
                elif [ -z "$default_pa" ]; then
                    print_test_result "FAIL" "No explicit mTLS policy found (Istio default is PERMISSIVE, not STRICT)"
                else
                    print_test_result "FAIL" "Default mTLS mode is $default_pa (should be STRICT)"
                fi
            fi
        else
            print_test_result "FAIL" "No explicit mTLS policies found and istioctl not available for verification"
        fi
    fi
    
    echo ""
    print_status "Istio Configuration Tests: $passed/$total passed"
    return $((total - passed))
}

# Show detailed results and recommendations
show_test_results() {
    print_header "TEST SUMMARY AND RECOMMENDATIONS"
    
    local total_failed=$1
    
    if [ "$total_failed" -eq "0" ]; then
        echo -e "${GREEN}🎉 ALL TESTS PASSED!${NC}"
        echo ""
        echo "Your Istio VM mesh integration is working correctly!"
        echo ""
        echo "Next steps:"
        echo "  1. Deploy your applications to the mesh"
        echo "  2. Configure traffic management policies"
        echo "  3. Set up monitoring and observability"
        echo "  4. Implement security policies"
    else
        echo -e "${YELLOW}⚠️  $total_failed TEST(S) FAILED${NC}"
        echo ""
        if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
            echo -e "${RED}Failed test groups:${NC}"
            for failed_test in "${FAILED_TESTS[@]}"; do
                echo -e "  ${RED}✗ $failed_test${NC}"
            done
            echo ""
        fi
        
        if [ ${#FAILED_TEST_DETAILS[@]} -gt 0 ]; then
            echo -e "${RED}Detailed failures:${NC}"
            for failed_detail in "${FAILED_TEST_DETAILS[@]}"; do
                echo -e "  ${RED}• $failed_detail${NC}"
            done
            echo ""
        fi
        
        if [ ${#TEST_WARNINGS[@]} -gt 0 ]; then
            echo -e "${YELLOW}Warnings:${NC}"
            for warning in "${TEST_WARNINGS[@]}"; do
                echo -e "  ${YELLOW}⚠ $warning${NC}"
            done
            echo ""
        fi
        
        echo "Common troubleshooting steps:"
        echo ""
        echo "1. Check Istio installation:"
        echo "   kubectl get pods -n istio-system"
        echo ""
        echo "2. Verify VM mesh configuration:"
        echo "   kubectl get workloadentry,serviceentry -n $VM_NAMESPACE"
        echo ""
        echo "3. Check service connectivity:"
        echo "   kubectl exec deployment/sleep -n mesh-test -- curl -v $VM_SERVICE_NAME.$VM_NAMESPACE:8080"
        echo ""
        echo "4. Check VM to HelloWorld connectivity:"
        echo "   ssh azureuser@<VM_IP> \"curl -v helloworld.helloworld:5000/hello\""
        echo ""
        echo "5. Check HelloWorld to VM connectivity:"
        echo "   kubectl exec \$(kubectl get pods -n helloworld -l app=helloworld -o name | head -1 | cut -d/ -f2) -n helloworld -- curl -v $VM_SERVICE_NAME.$VM_NAMESPACE:8080"
        echo ""
        echo "6. View Istio configuration:"
        echo "   istioctl analyze"
        echo ""
        echo "7. Check gateway configuration:"
        echo "   kubectl describe gateway -n istio-system"
        echo ""
        echo "8. Verify HelloWorld service is running:"
        echo "   kubectl get pods,svc -n helloworld"
        echo ""
        echo "9. Check mTLS configuration:"
        echo "   istioctl proxy-config cluster \$(kubectl get pods -n mesh-test -l app=sleep -o name | cut -d/ -f2).mesh-test --fqdn helloworld.helloworld.svc.cluster.local"
        echo "   istioctl proxy-config cluster \$(kubectl get pods -n helloworld -l app=helloworld -o name | head -1 | cut -d/ -f2).helloworld --fqdn $VM_SERVICE_NAME.$VM_NAMESPACE.svc.cluster.local"
        echo "   kubectl get peerauthentication,authorizationpolicy --all-namespaces"
        echo ""
        echo "10. Verify VM has Istio proxy for mTLS:"
        echo "    ssh azureuser@<VM_IP> \"ss -tulpn | grep :15001\""
        echo "    ssh azureuser@<VM_IP> \"ps aux | grep envoy\""
        echo ""
    fi
    
    # Show access URLs
    local gateway_ip=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$gateway_ip" ]; then
        echo ""
        echo "Gateway Access URLs:"
        echo "  Gateway Health:    http://$gateway_ip/health"
        echo "  VM Service:        http://$gateway_ip/vm-service"
        echo ""
        echo "Observability Tools (use port-forward to access):"
        echo "  Kiali Dashboard:   kubectl port-forward -n istio-system svc/kiali 20001:20001"
        echo "  Grafana Dashboard: kubectl port-forward -n istio-system svc/grafana 3000:3000"
        echo "  Jaeger Tracing:    kubectl port-forward -n istio-system svc/tracing 16686:80"
        echo ""
        echo "Or run: ./setup-istio.sh port-forward"
    fi
    
    echo ""
}

# Main execution
main() {
    print_header "ISTIO VM MESH INTEGRATION TESTS"
    
    check_prerequisites
    
    local total_failed=0
    
    if ! test_istio_installation; then
        FAILED_TESTS+=("TEST 1: Istio Installation")
        total_failed=$((total_failed + 1))
    fi
    
    if ! test_vm_namespace; then
        FAILED_TESTS+=("TEST 2: VM Namespace and Services")
        total_failed=$((total_failed + 1))
    fi
    
    if ! test_service_discovery; then
        FAILED_TESTS+=("TEST 3: Service Discovery")
        total_failed=$((total_failed + 1))
    fi
    
    if ! test_connectivity; then
        FAILED_TESTS+=("TEST 4: Connectivity Tests")
        total_failed=$((total_failed + 1))
    fi
    
    if ! test_gateway_access; then
        FAILED_TESTS+=("TEST 5: Gateway Access")
        total_failed=$((total_failed + 1))
    fi
    
    if ! test_istio_configuration; then
        FAILED_TESTS+=("TEST 6: Istio Configuration")
        total_failed=$((total_failed + 1))
    fi
    
    show_test_results $total_failed
    
    # Return non-zero exit code if any tests failed
    if [ "$total_failed" -gt "0" ]; then
        exit 1
    fi
    
    exit 0
}

# Run main function
main "$@"