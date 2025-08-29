#!/bin/bash

# Deploy Mesh Testing Applications
# This script deploys testing applications to validate mesh connectivity

set -e

# Shared configuration variables
VM_NAMESPACE="vm-workloads"
VM_APP="vm-web-service"

# Configuration variables
VM_SERVICE_NAME=$VM_APP

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

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."

    if ! kubectl cluster-info &> /dev/null; then
        print_error "Not connected to a Kubernetes cluster"
        exit 1
    fi
    print_status "Connected to cluster: $(kubectl config current-context)"

    # Check if Istio is installed
    print_status "Checking Istio installation..."
    if ! kubectl get namespace istio-system &> /dev/null; then
        print_error "Istio system namespace not found. Please install Istio first."
        exit 1
    fi
    
    # Check if Istio control plane is running
    if ! kubectl get deployment istiod -n istio-system &> /dev/null; then
        print_error "Istio control plane (istiod) not found. Please install Istio first."
        exit 1
    fi
    
    # Check if istiod is ready
    if ! kubectl wait --for=condition=available --timeout=30s deployment/istiod -n istio-system &> /dev/null; then
        print_error "Istio control plane is not ready. Please check Istio installation."
        exit 1
    fi
    print_status "✓ Istio control plane is running"
    
    # Check if Istio gateway is deployed
    if kubectl get service istio-ingressgateway -n istio-system &> /dev/null; then
        print_status "✓ Istio ingress gateway is deployed"
    else
        print_warning "Istio ingress gateway not found"
    fi
    
    # Check VM workloads namespace and mesh integration
    print_status "Checking VM mesh integration..."
    if ! kubectl get namespace $VM_NAMESPACE &> /dev/null; then
        print_error "VM workloads namespace not found. Execute ./setup-istio.sh setup-vm-mesh"
        exit 1
    else
        print_status "✓ VM workloads namespace exists"
        
        # Check if VM workloads namespace has Istio injection enabled
        if kubectl get namespace $VM_NAMESPACE -o jsonpath='{.metadata.labels.istio-injection}' | grep -q enabled; then
            print_status "✓ VM workloads namespace has Istio injection enabled"
        else
            print_warning "VM workloads namespace does not have Istio injection enabled"
        fi
        
        # Check for VM-related resources
        if kubectl get workloadgroup -n $VM_NAMESPACE &> /dev/null; then
            print_status "✓ WorkloadGroup resources found in $VM_NAMESPACE namespace"
        else
            print_warning "No WorkloadGroup resources found in $VM_NAMESPACE namespace"
        fi
        
        # Check for VM web service
        if kubectl get service $VM_SERVICE_NAME -n $VM_NAMESPACE &> /dev/null; then
            print_status "✓ VM web service found in $VM_NAMESPACE namespace"
        else
            print_warning "VM web service not found in $VM_NAMESPACE namespace"
        fi
        
        # Check for VM workload entries
        if kubectl get workloadentry -n $VM_NAMESPACE &> /dev/null; then
            VM_ENTRIES=$(kubectl get workloadentry -n $VM_NAMESPACE --no-headers | wc -l | tr -d ' ')
            print_status "✓ Found $VM_ENTRIES VM WorkloadEntry resources"
        else
            print_warning "No VM WorkloadEntry resources found"
        fi
    fi

    print_status "Prerequisites check passed!"
}

# Create and configure the mesh-test namespace
create_mesh_test_namespace() {
    print_status "Creating mesh-test namespace..."
    
    # Create namespace if it doesn't exist
    kubectl create namespace mesh-test --dry-run=client -o yaml | kubectl apply -f -
    
    # Label namespace for Istio injection
    kubectl label namespace mesh-test istio-injection=enabled --overwrite
    
    print_status "✅ mesh-test namespace created and configured for Istio injection"
}

# Deploy sleep pod for testing
deploy_sleep_pod() {
    print_status "Deploying sleep pod for testing..."
    
    # Check if sleep deployment already exists with different selector
    if kubectl get deployment sleep -n mesh-test &> /dev/null; then
        print_status "Sleep deployment exists, deleting and recreating..."
        kubectl delete deployment sleep -n mesh-test --ignore-not-found=true
        kubectl delete service sleep -n mesh-test --ignore-not-found=true
        kubectl delete serviceaccount sleep -n mesh-test --ignore-not-found=true
        sleep 10  # Wait for resources to be fully deleted
    fi
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sleep
  namespace: mesh-test
---
apiVersion: v1
kind: Service
metadata:
  name: sleep
  namespace: mesh-test
  labels:
    app: sleep
    service: sleep
spec:
  ports:
  - port: 80
    name: http
  selector:
    app: sleep
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep
  namespace: mesh-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sleep
  template:
    metadata:
      labels:
        app: sleep
    spec:
      terminationGracePeriodSeconds: 0
      serviceAccountName: sleep
      containers:
      - name: sleep
        image: curlimages/curl
        command: ["/bin/sleep", "infinity"]
        imagePullPolicy: IfNotPresent
        volumeMounts:
        - mountPath: /etc/sleep/tls
          name: secret-volume
      volumes:
      - name: secret-volume
        secret:
          secretName: sleep-secret
          optional: true
EOF
    
    print_status "Waiting for sleep pod to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/sleep -n mesh-test
}

# Deploy HTTPBin service for testing
deploy_httpbin_test() {
    print_status "Deploying HTTPBin test service..."
    
    # Check if httpbin deployment already exists with different selector
    if kubectl get deployment httpbin -n mesh-test &> /dev/null; then
        print_status "HTTPBin deployment exists, deleting and recreating..."
        kubectl delete deployment httpbin -n mesh-test --ignore-not-found=true
        kubectl delete service httpbin -n mesh-test --ignore-not-found=true
        kubectl delete serviceaccount httpbin -n mesh-test --ignore-not-found=true
        sleep 10  # Wait for resources to be fully deleted
    fi
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: httpbin
  namespace: mesh-test
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: mesh-test
  labels:
    app: httpbin
    service: httpbin
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: mesh-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      serviceAccountName: httpbin
      containers:
      - image: docker.io/kennethreitz/httpbin
        imagePullPolicy: IfNotPresent
        name: httpbin
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
EOF
    
    print_status "Waiting for HTTPBin to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/httpbin -n mesh-test
}

# Deploy network testing utilities
deploy_network_tools() {
    print_status "Deploying network testing utilities..."
    
    # Delete existing netshoot pod if it exists
    kubectl delete pod netshoot -n mesh-test --ignore-not-found=true
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: netshoot
  namespace: mesh-test
  labels:
    app: netshoot
spec:
  containers:
  - name: netshoot
    image: nicolaka/netshoot
    command: ["/bin/bash", "-c", "sleep infinity"]
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 256Mi
EOF
    
    print_status "Waiting for network tools to be ready..."
    kubectl wait --for=condition=ready --timeout=300s pod/netshoot -n mesh-test
}

# Create Gateway and VirtualService for test services
configure_test_gateway() {
    print_status "Configuring gateway for test services..."
    
    # Delete existing VirtualService if it exists
    kubectl delete virtualservice test-services -n mesh-test --ignore-not-found=true
    
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: test-services
  namespace: mesh-test
spec:
  hosts:
  - "*"
  gateways:
  - istio-system/istio-gateway
  http:
  - match:
    - uri:
        prefix: /httpbin
    rewrite:
      uri: /
    route:
    - destination:
        host: httpbin.mesh-test.svc.cluster.local
        port:
          number: 8000
  - match:
    - uri:
        prefix: /headers
    route:
    - destination:
        host: httpbin.mesh-test.svc.cluster.local
        port:
          number: 8000
    rewrite:
      uri: /headers
  - match:
    - uri:
        prefix: /vm-test
    route:
    - destination:
        host: $VM_SERVICE_NAME.$VM_NAMESPACE.svc.cluster.local
        port:
          number: 5000
EOF
    
    print_status "Test gateway configuration applied"
}

# Validate deployments
validate_deployments() {
    print_status "Validating test deployments..."
    
    # Check sleep pod
    if kubectl get pod -l app=sleep -n mesh-test | grep -q Running; then
        print_status "✓ Sleep pod is running"
    else
        print_warning "Sleep pod is not running"
        kubectl get pods -l app=sleep -n mesh-test
    fi
    
    # Check HTTPBin
    if kubectl get pod -l app=httpbin -n mesh-test | grep -q Running; then
        print_status "✓ HTTPBin is running"
    else
        print_warning "HTTPBin is not running"
        kubectl get pods -l app=httpbin -n mesh-test
    fi
    
    # Check VM namespace
    if kubectl get namespace $VM_NAMESPACE &> /dev/null; then
        print_status "✓ VM workloads namespace exists"
    else
        print_warning "VM workloads namespace not found"
    fi
    
    # Check netshoot
    if kubectl get pod netshoot -n mesh-test | grep -q Running; then
        print_status "✓ Network tools pod is running"
    else
        print_warning "Network tools pod is not running"
        kubectl get pod netshoot -n mesh-test
    fi
}

# Basic connectivity tests
run_basic_tests() {
    print_status "Running basic connectivity tests..."
    
    # Wait a bit for pods to be fully ready
    sleep 10
    
    # Test HTTPBin from sleep pod
    print_status "Testing HTTPBin connectivity from sleep pod..."
    if kubectl exec deployment/sleep -n mesh-test -- curl -s --max-time 10 httpbin:8000/headers | grep -q "User-Agent"; then
        print_status "✓ Sleep → HTTPBin connectivity works"
    else
        print_warning "Sleep → HTTPBin connectivity failed"
        print_status "Debugging HTTPBin connectivity..."
        kubectl exec deployment/sleep -n mesh-test -- nslookup httpbin || true
        kubectl get svc httpbin -n mesh-test || true
    fi
    
    # Test external connectivity
    print_status "Testing external connectivity..."
    if kubectl exec deployment/sleep -n mesh-test -- curl -s --max-time 10 httpbin.org/headers | grep -q "User-Agent"; then
        print_status "✓ Sleep → External HTTPBin.org connectivity works"
    else
        print_warning "Sleep → External HTTPBin.org connectivity failed (this might be expected in restricted networks)"
    fi
    
    # Test VM service connectivity
    print_status "Testing VM service connectivity..."
    if kubectl exec deployment/sleep -n mesh-test -- curl -s --max-time 10 $VM_SERVICE_NAME.$VM_NAMESPACE:8080 | grep -q "VM Web Service"; then
        print_status "✓ Sleep → VM service connectivity works"
    else
        print_warning "Sleep → VM service connectivity failed"
        print_status "Debugging VM service connectivity..."
        kubectl exec deployment/sleep -n mesh-test -- nslookup $VM_SERVICE_NAME.$VM_NAMESPACE || true
        kubectl get svc $VM_SERVICE_NAME -n $VM_NAMESPACE || true
    fi
}

# Show test results and next steps
show_test_results() {
    echo ""
    print_header "TEST DEPLOYMENT COMPLETE"
    echo ""
    print_status "✅ Mesh testing applications deployed successfully!"
    echo ""
    echo "Available test services (in mesh-test namespace):"
    echo "  - Sleep pod: kubectl exec -it deployment/sleep -n mesh-test -- sh"
    echo "  - HTTPBin: kubectl exec -it deployment/httpbin -n mesh-test -- sh"  
    echo "  - Network tools: kubectl exec -it pod/netshoot -n mesh-test -- bash"
    echo ""
    echo "Manual test commands:"
    echo "  # Test HTTPBin service"
    echo "  kubectl exec -it deployment/sleep -n mesh-test -- curl httpbin:8000/headers"
    echo ""
    echo "  # Test VM web service (backup)"
    echo "  kubectl exec -it deployment/sleep -n mesh-test -- curl $VM_SERVICE_NAME.$VM_NAMESPACE:8080"
    echo ""
    echo "  # DNS resolution tests"
    echo "  kubectl exec -it pod/netshoot -n mesh-test -- nslookup httpbin.mesh-test.svc.cluster.local"
    echo "  kubectl exec -it pod/netshoot -n mesh-test -- nslookup $VM_SERVICE_NAME.$VM_NAMESPACE.svc.cluster.local"
    echo ""
    echo "  # Network connectivity tests"
    echo "  kubectl exec -it pod/netshoot -n mesh-test -- ping httpbin.mesh-test.svc.cluster.local"
    echo ""
    
    # Show gateway access if available
    if kubectl get svc istio-ingressgateway -n istio-system &> /dev/null; then
        GATEWAY_IP=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
        if [ "$GATEWAY_IP" != "pending" ] && [ -n "$GATEWAY_IP" ]; then
            echo "External access via Gateway (IP: $GATEWAY_IP):"
            echo "  curl http://$GATEWAY_IP/headers"
            echo "  curl http://$GATEWAY_IP/httpbin"
            echo "  curl http://$GATEWAY_IP/vm-test"
        else
            echo "Gateway IP is still pending assignment..."
        fi
    fi
    echo ""
}

# Main execution
main() {
    print_header "DEPLOYING MESH TESTING APPLICATIONS"
    
    check_prerequisites
    create_mesh_test_namespace
    deploy_sleep_pod
    deploy_httpbin_test
    deploy_network_tools
    configure_test_gateway
    validate_deployments
    run_basic_tests
    show_test_results
}

# Run main function
main "$@"