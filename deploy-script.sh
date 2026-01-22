#!/bin/bash

# Task API - Deploy Script
# Revent Technologies DevOps Challenge
# Deployment-only script (image assumed to be already pushed)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
DOCKER_USERNAME="ekelejay"  # Your DockerHub username
IMAGE_NAME="task-api"
REGISTRY="${DOCKER_USERNAME}/${IMAGE_NAME}"
K8S_DIR="k8s"
DEPLOYMENT_FILE="${K8S_DIR}/deployment.yaml"
SERVICE_FILE="${K8S_DIR}/service.yaml"
METALLB_INSTALLED=false

# Default image tag (can be overridden)
IMAGE_TAG="${IMAGE_TAG:-latest}"

# Functions
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

error() {
    echo -e "${RED}✗ $1${NC}"
    exit 1
}

# Banner
echo -e "${PURPLE}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║            Task API - Deployment Script                       ║"
echo "║            Revent Technologies DevOps Challenge                ║"
echo "║                                                                ║"
echo "║                  Deploy to Kubernetes                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed. Please install kubectl first."
    fi
    
    # Check kubectl connection
    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot connect to Kubernetes cluster. Please configure kubectl."
    fi
    
    # Check if k8s directory exists
    if [ ! -d "${K8S_DIR}" ]; then
        error "Kubernetes configuration directory '${K8S_DIR}' not found."
    fi
    
    success "All prerequisites met!"
}

# Setup MetalLB for LoadBalancer services
setup_metallb() {
    log "Setting up MetalLB for LoadBalancer services..."
    
    # Check if MetalLB is already installed
    if kubectl get namespace metallb-system &> /dev/null; then
        warning "MetalLB namespace already exists"
        if kubectl get pods -n metallb-system &> /dev/null 2>&1; then
            log "MetalLB appears to be already installed"
            
            # Check if IPAddressPool exists and is valid
            if kubectl get ipaddresspool default-pool -n metallb-system &> /dev/null 2>&1; then
                log "IPAddressPool already exists, skipping MetalLB setup"
                METALLB_INSTALLED=true
                return 0
            else
                log "IPAddressPool not found, will create it"
            fi
        fi
    else
        # Install MetalLB
        log "Installing MetalLB..."
        kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
        
        # Wait for MetalLB to be ready
        log "Waiting for MetalLB pods to be ready..."
        kubectl wait --namespace metallb-system \
            --for=condition=ready pod \
            --selector=app=metallb \
            --timeout=90s
        
        success "MetalLB installed successfully!"
    fi
    
    # Get Docker network subnet for kind cluster
    log "Detecting cluster network range..."
    
    # Try to get kind network first (filter for IPv4 only)
    if docker network inspect kind &> /dev/null; then
        # Get only IPv4 subnet (filter out IPv6)
        SUBNET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' | head -1)
        log "   Detected kind subnet: $SUBNET"
    else
        # Fallback to bridge network
        warning "Kind network not found, using docker bridge network"
        SUBNET=$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' | head -1)
        log "   Detected bridge subnet: $SUBNET"
    fi
    
    if [ -z "$SUBNET" ]; then
        error "Could not detect IPv4 network subnet"
    fi
    
    # Extract IP range for MetalLB (using last 50 IPs of the subnet)
    # For example, if subnet is 172.21.0.0/16, we'll use 172.21.255.200-172.21.255.250
    BASE_IP=$(echo $SUBNET | cut -d'/' -f1 | cut -d'.' -f1-2)
    IP_START="${BASE_IP}.255.200"
    IP_END="${BASE_IP}.255.250"
    
    log "   MetalLB IP range: $IP_START - $IP_END"
    
    # Clean up any failed previous attempts
    log "🧹 Cleaning up any previous failed configurations..."
    kubectl delete ipaddresspool default-pool -n metallb-system 2>/dev/null || true
    kubectl delete l2advertisement default -n metallb-system 2>/dev/null || true
    
    # Wait a moment for cleanup
    sleep 2
    
    # Create MetalLB IPAddressPool and L2Advertisement
    log "⚙️  Configuring MetalLB IP address pool..."
    
    # Retry logic for creating resources
    MAX_RETRIES=3
    RETRY_COUNT=0
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - $IP_START-$IP_END
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF
        then
            # Verify the resources were created successfully
            sleep 2
            if kubectl get ipaddresspool default-pool -n metallb-system &> /dev/null && \
               kubectl get l2advertisement default -n metallb-system &> /dev/null; then
                success "MetalLB configured successfully!"
                break
            else
                warning "Resources created but verification failed, retrying..."
                RETRY_COUNT=$((RETRY_COUNT + 1))
                sleep 3
            fi
        else
            warning "Failed to create MetalLB resources, attempt $((RETRY_COUNT + 1))/$MAX_RETRIES"
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                log "Retrying in 3 seconds..."
                sleep 3
            fi
        fi
    done
    
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        error "Failed to configure MetalLB after $MAX_RETRIES attempts"
    fi
    
    # Verify configuration
    log "Verifying MetalLB configuration..."
    kubectl get ipaddresspool -n metallb-system
    kubectl get l2advertisement -n metallb-system
    
    METALLB_INSTALLED=true
    
    # Give MetalLB a moment to initialize
    log "⏳ Waiting for MetalLB to initialize..."
    sleep 5
}

# Update service to LoadBalancer type
update_service_to_loadbalancer() {
    log "Updating service to LoadBalancer type..."
    
    if [ ! -f "${SERVICE_FILE}" ]; then
        error "Service file not found: ${SERVICE_FILE}"
    fi
    
    # Create backup of original service file
    cp ${SERVICE_FILE} ${SERVICE_FILE}.backup
    
    # Update the service type to LoadBalancer
    cat > ${SERVICE_FILE} <<EOF
apiVersion: v1
kind: Service
metadata:
  name: task-api-service
  labels:
    app: task-api
spec:
  type: LoadBalancer
  selector:
    app: task-api
  ports:
  - protocol: TCP
    port: 80
    targetPort: 5000
    name: http
EOF
    
    success "Service configured as LoadBalancer type!"
}

# Update Kubernetes deployment with image tag
update_deployment_manifest() {
    log "Updating Kubernetes deployment manifest..."
    
    if [ ! -f "${DEPLOYMENT_FILE}" ]; then
        error "Deployment file not found: ${DEPLOYMENT_FILE}"
    fi
    
    # Create backup of original deployment file
    cp ${DEPLOYMENT_FILE} ${DEPLOYMENT_FILE}.backup
    
    # Update the image tag in deployment.yaml
    # This handles both placeholder format and existing image references
    sed -i.tmp "s|image:.*task-api.*|image: ${REGISTRY}:${IMAGE_TAG}|g" ${DEPLOYMENT_FILE}
    rm -f ${DEPLOYMENT_FILE}.tmp
    
    success "Deployment manifest updated with image: ${REGISTRY}:${IMAGE_TAG}"
    
    # Show the updated image line
    log "Updated image configuration:"
    grep -A 1 "image:" ${DEPLOYMENT_FILE} | head -2
}

# Deploy to Kubernetes
deploy_to_kubernetes() {
    log "Deploying to Kubernetes..."
    
    # Setup MetalLB if not already done
    if [ "$METALLB_INSTALLED" = false ]; then
        setup_metallb
        update_service_to_loadbalancer
    fi
    
    # Apply all Kubernetes manifests
    log "Applying deployment..."
    kubectl apply -f ${K8S_DIR}/deployment.yaml
    
    log "Applying service..."
    kubectl apply -f ${K8S_DIR}/service.yaml
    
    if [ -f "${K8S_DIR}/ingress.yaml" ]; then
        log "Ingress configuration found but using LoadBalancer instead..."
        warning "Skipping ingress.yaml (using LoadBalancer service)"
    fi
    
    # Wait for rollout to complete
    log "Waiting for deployment rollout..."
    kubectl rollout status deployment/task-api --timeout=300s
    
    if [ $? -eq 0 ]; then
        success "Deployment to Kubernetes completed successfully!"
        
        # Sometimes the service needs to be recreated to pick up the IP
        log "Ensuring LoadBalancer is properly configured..."
        kubectl delete service task-api-service 2>/dev/null || true
        sleep 2
        kubectl apply -f ${K8S_DIR}/service.yaml
        
        # Wait for LoadBalancer IP assignment
        log "⏳ Waiting for LoadBalancer IP assignment..."
        
        EXTERNAL_IP=""
        MAX_WAIT=60  # Wait up to 60 seconds
        WAIT_COUNT=0
        
        while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
            EXTERNAL_IP=$(kubectl get service task-api-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
            if [ ! -z "$EXTERNAL_IP" ]; then
                break
            fi
            echo -n "."
            sleep 2
            WAIT_COUNT=$((WAIT_COUNT + 2))
        done
        echo
        
        if [ ! -z "$EXTERNAL_IP" ]; then
            echo
            success "LoadBalancer IP assigned: ${EXTERNAL_IP}"
            echo
            log "Access your application at:"
            echo -e "${GREEN}   http://${EXTERNAL_IP}/tasks${NC}"
            echo -e "${GREEN}   http://${EXTERNAL_IP}/health${NC}"
            echo
            
            # Test the health endpoint
            log "🏥 Testing health endpoint..."
            sleep 3  # Give the app a moment to be ready
            if curl -s --max-time 5 "http://${EXTERNAL_IP}/health" &> /dev/null; then
                success "Application is responding and healthy!"
            else
                warning "Could not reach health endpoint yet (application may still be starting)"
            fi
        else
            warning "LoadBalancer IP not assigned after ${MAX_WAIT} seconds"
            echo
            log "Troubleshooting steps:"
            log "  1. Check MetalLB logs: kubectl logs -n metallb-system -l app=metallb"
            log "  2. Check service: kubectl describe svc task-api-service"
            log "  3. Check IPAddressPool: kubectl get ipaddresspool -n metallb-system"
            echo
        fi
    else
        error "Deployment rollout failed"
    fi
}

# Verify deployment
verify_deployment() {
    log "Verifying deployment..."
    echo
    
    log "Pods:"
    kubectl get pods -l app=task-api
    echo
    
    log "Deployment:"
    kubectl get deployment task-api
    echo
    
    log "Service:"
    kubectl get service task-api-service
    echo
    
    # Get LoadBalancer IP
    EXTERNAL_IP=$(kubectl get service task-api-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ ! -z "$EXTERNAL_IP" ]; then
        echo -e "${GREEN}LoadBalancer External IP: ${EXTERNAL_IP}${NC}"
        echo -e "${GREEN}   Access: http://${EXTERNAL_IP}/tasks${NC}"
        echo
        
        # Try to test the endpoint
        log "Testing health endpoint..."
        if curl -s --max-time 5 "http://${EXTERNAL_IP}/health" &> /dev/null; then
            success "Application is responding!"
        else
            warning "Could not reach application yet (may still be starting)"
        fi
        echo
    else
        warning "LoadBalancer IP not yet assigned"
        echo
    fi
    
    log "Recent Events:"
    kubectl get events --sort-by=.metadata.creationTimestamp | tail -5
    echo
    
    success "Deployment verification complete!"
}

# Rollback deployment
rollback_deployment() {
    log "Rolling back deployment..."
    
    # Restore backup deployment file
    if [ -f "${DEPLOYMENT_FILE}.backup" ]; then
        mv ${DEPLOYMENT_FILE}.backup ${DEPLOYMENT_FILE}
        log "Restored previous deployment manifest"
    fi
    
    # Rollback using kubectl
    kubectl rollout undo deployment/task-api
    
    log "Waiting for rollback to complete..."
    kubectl rollout status deployment/task-api --timeout=300s
    
    success "Rollback completed!"
    verify_deployment
}

# Show logs
show_logs() {
    log "Showing application logs..."
    
    POD_NAME=$(kubectl get pods -l app=task-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$POD_NAME" ]; then
        error "No pods found for task-api"
    fi
    
    log "Tailing logs from pod: ${POD_NAME}"
    kubectl logs -f ${POD_NAME}
}

# Show deployment status
show_status() {
    log "Task API Deployment Status"
    echo
    
    log "Kubernetes Resources:"
    echo
    kubectl get all -l app=task-api
    echo
    
    # Show LoadBalancer info
    log "LoadBalancer Service:"
    kubectl get service task-api-service
    EXTERNAL_IP=$(kubectl get service task-api-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ ! -z "$EXTERNAL_IP" ]; then
        echo
        echo -e "${GREEN}External IP: ${EXTERNAL_IP}${NC}"
        echo -e "${GREEN}   URL: http://${EXTERNAL_IP}${NC}"
    fi
    echo
    
    log "Deployment Details:"
    kubectl describe deployment task-api | grep -A 5 "Image:"
    echo
    
    # Try to get health status
    log "Application Health:"
    POD_NAME=$(kubectl get pods -l app=task-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ ! -z "$POD_NAME" ]; then
        kubectl exec ${POD_NAME} -- curl -s http://localhost:5000/health 2>/dev/null || warning "Could not check health endpoint"
    fi
}

# Delete deployment
delete_deployment() {
    log "Deleting Kubernetes deployment..."
    
    read -p "Are you sure you want to delete the deployment? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Deletion cancelled."
        exit 0
    fi
    
    kubectl delete -f ${K8S_DIR}/service.yaml 2>/dev/null || true
    kubectl delete -f ${K8S_DIR}/deployment.yaml 2>/dev/null || true
    
    success "Deployment deleted!"
    
    read -p "Do you want to remove MetalLB as well? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Removing MetalLB..."
        kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml 2>/dev/null || true
        success "MetalLB removed!"
    fi
}

# Full deployment pipeline
full_deployment() {
    log "Starting deployment pipeline with LoadBalancer..."
    echo
    
    log "Pipeline Steps:"
    log "  1. Check prerequisites"
    log "  2. Setup MetalLB (if needed)"
    log "  3. Update K8s manifest"
    log "  4. Configure LoadBalancer service"
    log "  5. Deploy to Kubernetes"
    log "  6. Verify deployment"
    echo
    
    read -p "Continue with deployment? (Y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        log "Deployment cancelled."
        exit 0
    fi
    
    check_prerequisites
    setup_metallb
    update_service_to_loadbalancer
    update_deployment_manifest
    deploy_to_kubernetes
    verify_deployment
    
    echo
    success "Deployment pipeline completed successfully!"
    echo
    log "Image deployed: ${REGISTRY}:${IMAGE_TAG}"
    
    EXTERNAL_IP=$(kubectl get service task-api-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ ! -z "$EXTERNAL_IP" ]; then
        log "Access your application at: http://${EXTERNAL_IP}"
    fi
}

# Setup MetalLB only
setup_metallb_only() {
    check_prerequisites
    setup_metallb
    update_service_to_loadbalancer
    
    log "Applying updated service..."
    kubectl apply -f ${SERVICE_FILE}
    
    success "MetalLB setup completed!"
    
    log "Service status:"
    kubectl get service task-api-service
}

# Show main menu
show_menu() {
    echo
    echo -e "${CYAN} Task API Deployment Management${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "1. Full deployment pipeline (recommended)"
    echo "2. Setup MetalLB LoadBalancer only"
    echo "3. Update K8s manifest only"
    echo "4. Deploy to K8s only"
    echo "5. Verify deployment"
    echo "6. Show logs"
    echo "7. Show status"
    echo "8. Rollback deployment"
    echo "9. Delete deployment"
    echo "0. Exit"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    read -p "Select option: " choice
    
    case $choice in
        1) full_deployment ;;
        2) setup_metallb_only ;;
        3) update_deployment_manifest ;;
        4) deploy_to_kubernetes; verify_deployment ;;
        5) verify_deployment ;;
        6) show_logs ;;
        7) show_status ;;
        8) rollback_deployment ;;
        9) delete_deployment ;;
        0) log "Goodbye!"; exit 0 ;;
        *) error "Invalid option" ;;
    esac
}

# Parse command line arguments
case ${1:-menu} in
    deploy|full)
        full_deployment
        ;;
    metallb)
        setup_metallb_only
        ;;
    update)
        update_deployment_manifest
        ;;
    k8s)
        deploy_to_kubernetes
        verify_deployment
        ;;
    verify)
        verify_deployment
        ;;
    logs)
        show_logs
        ;;
    status)
        show_status
        ;;
    rollback)
        rollback_deployment
        ;;
    delete)
        delete_deployment
        ;;
    help)
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  deploy/full  - Run full deployment pipeline"
        echo "  metallb      - Setup MetalLB LoadBalancer only"
        echo "  update       - Update K8s manifest"
        echo "  k8s          - Deploy to Kubernetes"
        echo "  verify       - Verify deployment"
        echo "  logs         - Show application logs"
        echo "  status       - Show deployment status"
        echo "  rollback     - Rollback to previous version"
        echo "  delete       - Delete deployment"
        echo "  menu         - Show interactive menu (default)"
        echo ""
        echo "Environment Variables:"
        echo "  IMAGE_TAG    - Docker image tag to deploy (default: latest)"
        echo ""
        echo "Examples:"
        echo "  $0 deploy                    # Deploy latest image"
        echo "  IMAGE_TAG=v1.2.3 $0 deploy  # Deploy specific version"
        ;;
    menu|*)
        while true; do
            show_menu
        done
        ;;
esac