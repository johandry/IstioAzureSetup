#!/bin/bash
# filepath: /Users/johandry.amador/Workspace/Sandbox/istio/azure-setup/scripts/deploy-samples.sh

# Deploy Istio Sample Applications with VM Mesh Integration for Azure AKS
# This script deploys common Istio samples and VM mesh testing applications

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

# Configuration - Use workspace directory structure
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(dirname "$SCRIPT_DIR")/workspace"
ISTIO_DIR="$WORKSPACE_DIR/istio-installation"
SAMPLES_DIR="$ISTIO_DIR/samples"

# Check if Istio is installed
check_istio() {
    print_status "Checking Istio installation..."
    
    if ! kubectl get namespace istio-system &> /dev/null; then
        print_error "Istio system namespace not found. Please install Istio first."
        print_status "Run: ./setup-istio.sh setup"
        exit 1
    fi
    
    if ! kubectl get deployment istiod -n istio-system &> /dev/null; then
        print_error "Istiod not found. Please install Istio first."
        print_status "Run: ./setup-istio.sh setup"
        exit 1
    fi
    
    # Check if istiod is ready
    local ready_replicas=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$ready_replicas" -lt "1" ]; then
        print_warning "Istiod is not ready yet. Waiting..."
        kubectl wait --for=condition=available --timeout=300s deployment/istiod -n istio-system
    fi
    
    print_status "✓ Istio installation verified!"
}

# Ensure Istio samples are available in workspace
ensure_istio_samples() {
    print_status "Ensuring Istio samples are available in workspace..."
    
    # Check if samples already exist in workspace
    if [ -d "$SAMPLES_DIR" ] && [ "$(ls -A "$SAMPLES_DIR" 2>/dev/null)" ]; then
        print_status "✓ Istio samples found in workspace: $SAMPLES_DIR"
        local sample_count=$(find "$SAMPLES_DIR" -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
        print_status "✓ Found $sample_count sample YAML files"
        return 0
    fi
    
    print_status "Istio samples not found in workspace, downloading..."
    
    # Create workspace structure
    mkdir -p "$WORKSPACE_DIR"
    cd "$WORKSPACE_DIR"
    
    # Download Istio if not present in workspace
    if [ ! -d "$ISTIO_DIR" ]; then
        print_status "Downloading Istio to workspace directory..."
        curl -L https://istio.io/downloadIstio | sh -
        
        # Move to organized structure
        local istio_download_dir=$(find . -maxdepth 1 -name "istio-*" -type d | head -1)
        if [ -n "$istio_download_dir" ] && [ -d "$istio_download_dir" ]; then
            mv "$istio_download_dir" istio-installation
            print_status "✓ Istio downloaded with samples to: $ISTIO_DIR"
        else
            print_error "Failed to download Istio"
            exit 1
        fi
    fi
    
    # Verify samples directory exists
    if [ ! -d "$SAMPLES_DIR" ]; then
        print_error "Samples directory not found: $SAMPLES_DIR"
        exit 1
    fi
    
    local sample_count=$(find "$SAMPLES_DIR" -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
    print_status "✓ Istio samples ready in workspace ($sample_count YAML files)"
    
    cd "$SCRIPT_DIR"
}

# Deploy Bookinfo application
deploy_bookinfo() {
    print_header "DEPLOYING BOOKINFO APPLICATION"
    
    ensure_istio_samples
    
    local bookinfo_dir="$SAMPLES_DIR/bookinfo"
    if [ ! -d "$bookinfo_dir" ]; then
        print_error "Bookinfo samples not found in: $bookinfo_dir"
        exit 1
    fi
    
    print_status "Deploying Bookinfo application from samples..."
    
    # Deploy Bookinfo
    kubectl apply -f "$bookinfo_dir/platform/kube/bookinfo.yaml"
    
    # Wait for deployments
    print_status "Waiting for Bookinfo pods to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/productpage-v1
    kubectl wait --for=condition=available --timeout=300s deployment/details-v1
    kubectl wait --for=condition=available --timeout=300s deployment/ratings-v1
    kubectl wait --for=condition=available --timeout=300s deployment/reviews-v1
    kubectl wait --for=condition=available --timeout=300s deployment/reviews-v2
    kubectl wait --for=condition=available --timeout=300s deployment/reviews-v3
    
    # Create gateway
    kubectl apply -f "$bookinfo_dir/networking/bookinfo-gateway.yaml"
    
    # Create destination rules
    kubectl apply -f "$bookinfo_dir/networking/destination-rule-all.yaml"
    
    print_status "Bookinfo application deployed successfully!"
}

# Deploy HTTPBin application
deploy_httpbin() {
    print_status "Deploying HTTPBin application..."
    
    if [ ! -d "$SAMPLES_DIR" ]; then
        print_error "Istio samples not found. Please run deploy_bookinfo first."
        exit 1
    fi
    
    kubectl apply -f "$SAMPLES_DIR/httpbin/httpbin.yaml"
    kubectl apply -f "$SAMPLES_DIR/httpbin/httpbin-gateway.yaml"
    
    print_status "HTTPBin application deployed successfully!"
}

# Deploy Sleep application (useful for testing)
deploy_sleep() {
    print_status "Deploying Sleep application (for testing)..."
    
    if [ ! -d "$SAMPLES_DIR" ]; then
        print_error "Istio samples not found. Please run deploy_bookinfo first."
        exit 1
    fi
    
    kubectl apply -f "$SAMPLES_DIR/sleep/sleep.yaml"
    
    print_status "Sleep application deployed successfully!"
}

# Deploy HelloWorld application
deploy_helloworld() {
    print_status "Deploying HelloWorld application..."
    
    if [ ! -d "$SAMPLES_DIR" ]; then
        print_error "Istio samples not found. Please run deploy_bookinfo first."
        exit 1
    fi
    
    kubectl apply -f "$SAMPLES_DIR/helloworld/helloworld.yaml"
    kubectl apply -f "$SAMPLES_DIR/helloworld/helloworld-gateway.yaml"
    
    print_status "HelloWorld application deployed successfully!"
}

# Get gateway information
get_gateway_info() {
    print_status "Getting gateway information..."
    
    # Get external IP
    EXTERNAL_IP=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    
    if [ -z "$EXTERNAL_IP" ]; then
        print_warning "External IP not yet assigned. Waiting..."
        kubectl get svc istio-ingressgateway -n istio-system -w &
        WATCH_PID=$!
        sleep 30
        kill $WATCH_PID 2>/dev/null || true
        EXTERNAL_IP=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    fi
    
    if [ -z "$EXTERNAL_IP" ]; then
        print_warning "External IP still not assigned. You may need to wait longer."
        EXTERNAL_IP="<pending>"
    fi
    
    GATEWAY_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
    
    echo ""
    echo "========================================="
    echo "APPLICATION ACCESS INFORMATION"
    echo "========================================="
    echo ""
    echo "External IP: $EXTERNAL_IP"
    echo "Gateway Port: $GATEWAY_PORT"
    echo ""
    echo "Application URLs (once External IP is assigned):"
    echo "  Bookinfo: http://$EXTERNAL_IP:$GATEWAY_PORT/productpage"
    echo "  HTTPBin: http://$EXTERNAL_IP:$GATEWAY_PORT/headers"
    echo "  HelloWorld: http://$EXTERNAL_IP:$GATEWAY_PORT/hello"
    echo ""
    echo "Istio Services (use port-forward):"
    echo "  Kiali: kubectl port-forward -n istio-system svc/kiali 20001:20001"
    echo "  Grafana: kubectl port-forward -n istio-system svc/grafana 3000:3000"
    echo "  Jaeger: kubectl port-forward -n istio-system svc/jaeger 16686:16686"
    echo ""
}

# Create test scripts
create_test_scripts() {
    print_status "Creating test scripts..."
    
    mkdir -p ~/istio-workspace/scripts
    
    # Traffic generation script
    cat > ~/istio-workspace/scripts/generate-traffic.sh << 'EOF'
#!/bin/bash
# Generate traffic to test applications

GATEWAY_URL=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
GATEWAY_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')

if [ -z "$GATEWAY_URL" ]; then
    echo "Gateway URL not available yet. Please wait for LoadBalancer to be assigned."
    exit 1
fi

echo "Generating traffic to Bookinfo application..."
echo "Gateway URL: http://$GATEWAY_URL:$GATEWAY_PORT"

for i in {1..100}; do
    curl -s -o /dev/null "http://$GATEWAY_URL:$GATEWAY_PORT/productpage"
    echo -n "."
    sleep 1
done

echo ""
echo "Traffic generation completed!"
EOF

    # Internal test script (using sleep pod)
    cat > ~/istio-workspace/scripts/internal-test.sh << 'EOF'
#!/bin/bash
# Test applications from inside the cluster

echo "Testing applications from sleep pod..."

# Wait for sleep pod to be ready
kubectl wait --for=condition=ready pod -l app=sleep --timeout=300s

SLEEP_POD=$(kubectl get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')

echo "Using sleep pod: $SLEEP_POD"

echo ""
echo "Testing Bookinfo productpage:"
kubectl exec $SLEEP_POD -c sleep -- curl -s productpage:9080/productpage | grep -o "<title>.*</title>"

echo ""
echo "Testing HTTPBin:"
kubectl exec $SLEEP_POD -c sleep -- curl -s httpbin:8000/headers

echo ""
echo "Testing HelloWorld:"
kubectl exec $SLEEP_POD -c sleep -- curl -s helloworld:5000/hello
EOF

    chmod +x ~/istio-workspace/scripts/*.sh
    
    print_status "Test scripts created in ~/istio-workspace/scripts/"
}

# Show status
show_status() {
    print_status "Checking deployment status..."
    
    echo ""
    echo "Pods in default namespace:"
    kubectl get pods
    
    echo ""
    echo "Services in default namespace:"
    kubectl get services
    
    echo ""
    echo "Istio Gateway:"
    kubectl get gateway
    
    echo ""
    echo "Virtual Services:"
    kubectl get virtualservice
    
    echo ""
    echo "Destination Rules:"
    kubectl get destinationrule
}

# Main menu
show_menu() {
    echo ""
    echo "========================================="
    echo "Istio Sample Applications Deployment"
    echo "========================================="
    echo ""
    echo "Choose an option:"
    echo "1. Deploy all applications"
    echo "2. Deploy Bookinfo only"
    echo "3. Deploy HTTPBin only"
    echo "4. Deploy Sleep only"
    echo "5. Deploy HelloWorld only"
    echo "6. Show status"
    echo "7. Get access information"
    echo "8. Exit"
    echo ""
    read -p "Enter your choice (1-8): " choice
    
    case $choice in
        1)
            check_istio
            deploy_bookinfo
            deploy_httpbin
            deploy_sleep
            deploy_helloworld
            create_test_scripts
            get_gateway_info
            show_status
            ;;
        2)
            check_istio
            deploy_bookinfo
            create_test_scripts
            get_gateway_info
            ;;
        3)
            check_istio
            deploy_httpbin
            ;;
        4)
            check_istio
            deploy_sleep
            create_test_scripts
            ;;
        5)
            check_istio
            deploy_helloworld
            ;;
        6)
            show_status
            ;;
        7)
            get_gateway_info
            ;;
        8)
            print_status "Goodbye!"
            exit 0
            ;;
        *)
            print_error "Invalid choice. Please select 1-8."
            show_menu
            ;;
    esac
}

# Main execution
main() {
    if [ $# -eq 0 ]; then
        show_menu
    else
        case $1 in
            --all)
                check_istio
                deploy_bookinfo
                deploy_httpbin
                deploy_sleep
                deploy_helloworld
                create_test_scripts
                get_gateway_info
                show_status
                ;;
            --bookinfo)
                check_istio
                deploy_bookinfo
                create_test_scripts
                get_gateway_info
                ;;
            --status)
                show_status
                ;;
            --info)
                get_gateway_info
                ;;
            *)
                echo "Usage: $0 [--all|--bookinfo|--status|--info]"
                echo "Or run without arguments for interactive menu"
                exit 1
                ;;
        esac
    fi
}

# Run main function
main "$@"
