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
    fi
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

    # TODO: Fix this test
    # Test basic connectivity to VM service
    ((total++))
    if kubectl exec deployment/sleep -n mesh-test -- curl -s --max-time $TEST_TIMEOUT "$VM_SERVICE_NAME.$VM_NAMESPACE:8080" | grep -q "VM Web Service"; then
        print_test_result "PASS" "VM service HTTP connectivity works"
        ((passed++))
    else
        print_test_result "FAIL" "VM service HTTP connectivity failed"
        # Debug information
        print_status "Debug: Testing VM service connectivity..."
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
    
    # Test observability tools through gateway
    ((total++))
    local obs_accessible=0
    if curl -s --max-time 10 "http://$gateway_ip/kiali" | grep -q "kiali\|Kiali\|login"; then
        ((obs_accessible++))
    fi
    if curl -s --max-time 10 "http://$gateway_ip/grafana" | grep -q "grafana\|Grafana\|dashboard"; then
        ((obs_accessible++))
    fi
    if curl -s --max-time 10 "http://$gateway_ip/jaeger" | grep -q "jaeger\|Jaeger\|tracing"; then
        ((obs_accessible++))
    fi
    
    if [ "$obs_accessible" -gt "0" ]; then
        print_test_result "PASS" "Observability tools accessible through gateway ($obs_accessible/3)"
        ((passed++))
    else
        print_test_result "FAIL" "No observability tools accessible through gateway"
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
        echo "4. View Istio configuration:"
        echo "   istioctl analyze"
        echo ""
        echo "5. Check gateway configuration:"
        echo "   kubectl describe gateway -n istio-system"
        echo ""
    fi
    
    # Show access URLs
    local gateway_ip=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$gateway_ip" ]; then
        echo ""
        echo "Access URLs:"
        echo "  Gateway Health:    http://$gateway_ip/health"
        echo "  VM Service:        http://$gateway_ip/vm-service"
        echo "  Kiali Dashboard:   http://$gateway_ip/kiali"
        echo "  Grafana:          http://$gateway_ip/grafana"
        echo "  Jaeger:           http://$gateway_ip/jaeger"
    fi
    
    echo ""
}

# Main execution
main() {
    print_header "ISTIO VM MESH INTEGRATION TESTS"
    
    check_prerequisites
    
    local total_failed=0
    
    test_istio_installation
    total_failed=$((total_failed + $?))
    
    test_vm_namespace
    total_failed=$((total_failed + $?))
    
    test_service_discovery
    total_failed=$((total_failed + $?))
    
    test_connectivity
    total_failed=$((total_failed + $?))
    
    test_gateway_access
    total_failed=$((total_failed + $?))
    
    test_istio_configuration
    total_failed=$((total_failed + $?))
    
    show_test_results $total_failed
    
    # Return non-zero exit code if any tests failed
    if [ "$total_failed" -gt "0" ]; then
        exit 1
    fi
    
    exit 0
}

# Run main function
main "$@"