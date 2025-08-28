#!/bin/bash

# Deploy Mesh Testing Applications
# This script deploys testing applications to validate mesh connectivity

set -e

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

# Check if we're connected to a Kubernetes cluster
check_cluster_connection() {
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Not connected to a Kubernetes cluster"
        exit 1
    fi
    
    print_status "Connected to cluster: $(kubectl config current-context)"
}

# Deploy sleep pod for testing
deploy_sleep_pod() {
    print_status "Deploying sleep pod for testing..."
    
    # Check if sleep deployment already exists with different selector
    if kubectl get deployment sleep &> /dev/null; then
        print_status "Sleep deployment exists, deleting and recreating..."
        kubectl delete deployment sleep --ignore-not-found=true
        kubectl delete service sleep --ignore-not-found=true
        kubectl delete serviceaccount sleep --ignore-not-found=true
        sleep 10  # Wait for resources to be fully deleted
    fi
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sleep
  namespace: default
---
apiVersion: v1
kind: Service
metadata:
  name: sleep
  namespace: default
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
  namespace: default
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
    kubectl wait --for=condition=available --timeout=300s deployment/sleep
}

# Deploy HTTPBin service for testing
deploy_httpbin_test() {
    print_status "Deploying HTTPBin test service..."
    
    # Check if httpbin deployment already exists with different selector
    if kubectl get deployment httpbin &> /dev/null; then
        print_status "HTTPBin deployment exists, deleting and recreating..."
        kubectl delete deployment httpbin --ignore-not-found=true
        kubectl delete service httpbin --ignore-not-found=true
        kubectl delete serviceaccount httpbin --ignore-not-found=true
        sleep 10  # Wait for resources to be fully deleted
    fi
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: httpbin
  namespace: default
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: default
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
  namespace: default
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
    kubectl wait --for=condition=available --timeout=300s deployment/httpbin
}

# Deploy test namespace for VM workloads
deploy_vm_test_namespace() {
    print_status "Creating VM workloads test namespace..."
    
    kubectl create namespace vm-workloads --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace vm-workloads istio-injection=enabled --overwrite
    
    # Check if vm-web-service-backup deployment exists and handle it
    if kubectl get deployment vm-web-service-backup -n vm-workloads &> /dev/null; then
        print_status "VM web service backup deployment exists, updating..."
        kubectl delete deployment vm-web-service-backup -n vm-workloads --ignore-not-found=true
        sleep 5
    fi
    
    # Deploy a test service that mimics VM workload
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: vm-web-service
  namespace: vm-workloads
  labels:
    app: vm-web-service
    service: vm-web-service
spec:
  ports:
  - port: 8080
    name: http
  selector:
    app: vm-web-service
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vm-web-content
  namespace: vm-workloads
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head>
        <title>VM Web Service (Backup)</title>
    </head>
    <body>
        <h1>VM Web Service - Backup Instance</h1>
        <p>This is a backup instance running in Kubernetes</p>
        <p>Source: Kubernetes Pod</p>
        <p>Version: backup</p>
        <p>Timestamp: $(date)</p>
    </body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vm-web-service-backup
  namespace: vm-workloads
  labels:
    app: vm-web-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vm-web-service
      version: backup
  template:
    metadata:
      labels:
        app: vm-web-service
        version: backup
    spec:
      containers:
      - name: web-service
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 256Mi
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
      volumes:
      - name: html
        configMap:
          name: vm-web-content
EOF
    
    print_status "VM test namespace and backup service created"
}

# Deploy network testing utilities
deploy_network_tools() {
    print_status "Deploying network testing utilities..."
    
    # Delete existing netshoot pod if it exists
    kubectl delete pod netshoot --ignore-not-found=true
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: netshoot
  namespace: default
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
    kubectl wait --for=condition=ready --timeout=300s pod/netshoot
}

# Create Gateway and VirtualService for test services
configure_test_gateway() {
    print_status "Configuring gateway for test services..."
    
    # Delete existing VirtualService if it exists
    kubectl delete virtualservice test-services --ignore-not-found=true
    
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: test-services
  namespace: default
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
        host: httpbin.default.svc.cluster.local
        port:
          number: 8000
  - match:
    - uri:
        prefix: /headers
    route:
    - destination:
        host: httpbin.default.svc.cluster.local
        port:
          number: 8000
    rewrite:
      uri: /headers
  - match:
    - uri:
        prefix: /vm-test
    route:
    - destination:
        host: vm-web-service.vm-workloads.svc.cluster.local
        port:
          number: 8080
EOF
    
    print_status "Test gateway configuration applied"
}

# Validate deployments
validate_deployments() {
    print_status "Validating test deployments..."
    
    # Check sleep pod
    if kubectl get pod -l app=sleep | grep -q Running; then
        print_status "✓ Sleep pod is running"
    else
        print_warning "Sleep pod is not running"
        kubectl get pods -l app=sleep
    fi
    
    # Check HTTPBin
    if kubectl get pod -l app=httpbin | grep -q Running; then
        print_status "✓ HTTPBin is running"
    else
        print_warning "HTTPBin is not running"
        kubectl get pods -l app=httpbin
    fi
    
    # Check VM namespace
    if kubectl get namespace vm-workloads &> /dev/null; then
        print_status "✓ VM workloads namespace exists"
        if kubectl get pod -l app=vm-web-service -n vm-workloads | grep -q Running; then
            print_status "✓ VM web service backup is running"
        else
            print_warning "VM web service backup is not running"
            kubectl get pods -l app=vm-web-service -n vm-workloads
        fi
    else
        print_warning "VM workloads namespace not found"
    fi
    
    # Check netshoot
    if kubectl get pod netshoot | grep -q Running; then
        print_status "✓ Network tools pod is running"
    else
        print_warning "Network tools pod is not running"
        kubectl get pod netshoot
    fi
}

# Basic connectivity tests
run_basic_tests() {
    print_status "Running basic connectivity tests..."
    
    # Wait a bit for pods to be fully ready
    sleep 10
    
    # Test HTTPBin from sleep pod
    print_status "Testing HTTPBin connectivity from sleep pod..."
    if kubectl exec deployment/sleep -- curl -s --max-time 10 httpbin:8000/headers | grep -q "User-Agent"; then
        print_status "✓ Sleep → HTTPBin connectivity works"
    else
        print_warning "Sleep → HTTPBin connectivity failed"
        print_status "Debugging HTTPBin connectivity..."
        kubectl exec deployment/sleep -- nslookup httpbin || true
        kubectl get svc httpbin || true
    fi
    
    # Test external connectivity
    print_status "Testing external connectivity..."
    if kubectl exec deployment/sleep -- curl -s --max-time 10 httpbin.org/headers | grep -q "User-Agent"; then
        print_status "✓ External connectivity works"
    else
        print_warning "External connectivity failed (this might be expected in restricted networks)"
    fi
    
    # Test VM service connectivity
    print_status "Testing VM service connectivity..."
    if kubectl exec deployment/sleep -- curl -s --max-time 10 vm-web-service.vm-workloads:8080 | grep -q "VM Web Service"; then
        print_status "✓ Sleep → VM service connectivity works"
    else
        print_warning "Sleep → VM service connectivity failed"
        print_status "Debugging VM service connectivity..."
        kubectl exec deployment/sleep -- nslookup vm-web-service.vm-workloads || true
        kubectl get svc vm-web-service -n vm-workloads || true
    fi
}

# Show test results and next steps
show_test_results() {
    echo ""
    print_header "TEST DEPLOYMENT COMPLETE"
    echo ""
    print_status "✅ Mesh testing applications deployed successfully!"
    echo ""
    echo "Available test services:"
    echo "  - Sleep pod: kubectl exec -it deployment/sleep -- sh"
    echo "  - HTTPBin: kubectl exec -it deployment/httpbin -- sh"  
    echo "  - Network tools: kubectl exec -it pod/netshoot -- bash"
    echo ""
    echo "Manual test commands:"
    echo "  # Test HTTPBin service"
    echo "  kubectl exec -it deployment/sleep -- curl httpbin:8000/headers"
    echo ""
    echo "  # Test VM web service (backup)"
    echo "  kubectl exec -it deployment/sleep -- curl vm-web-service.vm-workloads:8080"
    echo ""
    echo "  # DNS resolution tests"
    echo "  kubectl exec -it pod/netshoot -- nslookup httpbin.default.svc.cluster.local"
    echo "  kubectl exec -it pod/netshoot -- nslookup vm-web-service.vm-workloads.svc.cluster.local"
    echo ""
    echo "  # Network connectivity tests"
    echo "  kubectl exec -it pod/netshoot -- ping httpbin.default.svc.cluster.local"
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
    
    check_cluster_connection
    deploy_sleep_pod
    deploy_httpbin_test
    deploy_vm_test_namespace
    deploy_network_tools
    configure_test_gateway
    validate_deployments
    run_basic_tests
    show_test_results
}

# Run main function
main "$@"