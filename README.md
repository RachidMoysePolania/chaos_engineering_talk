# Manual Setup Guide for Istio Chaos Engineering Lab on EKS

## Prerequisites Check

```bash
# Check AWS CLI
aws --version

# Check kubectl
kubectl version --client

# Check eksctl
eksctl version

# Check helm
helm version
```

## Step 1: Create EKS Cluster Manually

### Option A: Using eksctl (Easier)

```bash
# Create cluster with eksctl
eksctl create cluster \
  --name istio-chaos-lab \
  --region us-east-1 \
  --version 1.30 \
  --nodegroup-name standard-workers \
  --node-type t3.medium \
  --nodes 3 \
  --nodes-min 2 \
  --nodes-max 5 \
  --managed \
  --with-oidc \
  --ssh-access \
  --ssh-public-key ~/.ssh/id_rsa.pub

# This will automatically update your kubeconfig
```

### Option B: Using AWS Console

1. Go to EKS in AWS Console
2. Click "Add cluster" → "Create"
3. Configure:
   - Name: `istio-chaos-lab`
   - Kubernetes version: `1.30` (1.33 might not be available)
   - Cluster service role: Create new or select existing
   - Networking: Select VPC and subnets
   - Security group: Create new
   - Cluster endpoint access: Public and private
   - Add your IP to allowed list
4. Create Node Group:
   - Name: `standard-workers`
   - Node IAM role: Create new with required policies
   - AMI type: Amazon Linux 2023
   - Instance type: t3.medium
   - Scaling: Min 2, Desired 3, Max 5

### Update kubeconfig (if using console)

```bash
aws eks update-kubeconfig --name istio-chaos-lab --region us-east-1

# Verify connection
kubectl get nodes
```

## Step 2: Install AWS Load Balancer Controller

### 2.1 Create IAM Policy

```bash
# Download the policy
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/docs/install/iam_policy.json

# Create the policy
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json
```

### 2.2 Create Service Account with IAM Role

```bash
# Get cluster OIDC URL
CLUSTER_NAME=istio-chaos-lab
REGION=us-east-1
OIDC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)

# Check if OIDC provider exists
aws iam list-open-id-connect-providers | grep $OIDC_ID

# If not exists, create it
eksctl utils associate-iam-oidc-provider --cluster=$CLUSTER_NAME --region=$REGION --approve

# Create service account with IAM role
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AWSLoadBalancerControllerIAMPolicy \
  --approve \
  --region=$REGION
```

### 2.3 Install the Controller

```bash
# Add the eks-charts repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install the AWS Load Balancer Controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$REGION

# Verify installation
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get pods -n kube-system | grep aws-load-balancer
```

## Step 3: Install Istio

### 3.1 Download and Install Istio CLI

```bash
# Download Istio
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.21.0 sh -
cd istio-1.21.0
export PATH=$PWD/bin:$PATH

# Verify istioctl
istioctl version
```

### 3.2 Install Istio

```bash
# Install Istio with demo profile
istioctl install --set profile=demo -y

# Verify installation
kubectl get pods -n istio-system
kubectl get svc -n istio-system

# Label default namespace for sidecar injection
kubectl label namespace default istio-injection=enabled
```

## Step 4: Configure Istio Gateway with ACM

### 4.1 Get Your ACM Certificate ARN

```bash
# List certificates
aws acm list-certificates --region $REGION

# Or create new certificate if needed
# Note: Domain must be validated
```

### 4.2 Patch Istio Ingress Gateway Service

```bash
# Create patch file
cat <<EOF > istio-nlb-patch.yaml
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "arn:aws:acm:REGION:ACCOUNT:certificate/CERT-ID"
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "https"
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "tcp"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
    name: http2
    protocol: TCP
  - port: 443
    targetPort: 8080
    name: https
    protocol: TCP
EOF

# Replace REGION, ACCOUNT, and CERT-ID with your values
# Apply the patch
kubectl patch svc istio-ingressgateway -n istio-system --patch-file istio-nlb-patch.yaml
```

### 4.3 Get Load Balancer DNS

```bash
# Wait for Load Balancer to be provisioned (may take 2-3 minutes)
kubectl get svc istio-ingressgateway -n istio-system -w

# Get the DNS name
export INGRESS_HOST=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Load Balancer DNS: $INGRESS_HOST"
```

### 4.4 Update Route53

1. Go to Route53 Console
2. Select your hosted zone
3. Create Record:
   - Record name: `bookinfo` (or your subdomain)
   - Record type: A
   - Alias: Yes
   - Route traffic to: Application and Classic Load Balancer
   - Region: Select your region
   - Load balancer: Select the NLB created by Istio

## Step 5: Deploy Bookinfo Application

### 5.1 Deploy the Application

```bash
# Make sure you're in istio directory
cd ~/istio-1.21.0

# Deploy Bookinfo
kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml

# Wait for pods to be ready
kubectl get pods -w

# Verify services
kubectl get svc
```

### 5.2 Create Gateway and VirtualService

```bash
# Create Gateway
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: bookinfo-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
  - port:
      number: 443
      name: https
      protocol: HTTP
    hosts:
    - "bookinfo.yourdomain.com"  # Replace with your domain
EOF

# Apply VirtualService
kubectl apply -f samples/bookinfo/networking/bookinfo-gateway.yaml

# Apply destination rules
kubectl apply -f samples/bookinfo/networking/destination-rule-all.yaml
```

### 5.3 Test the Application

```bash
# Test using Load Balancer DNS
curl -s http://$INGRESS_HOST/productpage | grep -o "<title>.*</title>"

# Test using your domain (after DNS propagation)
curl -s https://bookinfo.yourdomain.com/productpage | grep -o "<title>.*</title>"

# Or open in browser
echo "http://$INGRESS_HOST/productpage"
```

## Step 6: Install Observability Add-ons

### 6.1 Install Prometheus, Grafana, Jaeger, and Kiali

```bash
# Install all observability add-ons
kubectl apply -f samples/addons/prometheus.yaml
kubectl apply -f samples/addons/grafana.yaml
kubectl apply -f samples/addons/jaeger.yaml
kubectl apply -f samples/addons/kiali.yaml

# Wait for all pods to be ready
kubectl get pods -n istio-system -w
```

### 6.2 Access Kiali Dashboard

```bash
# Port forward Kiali
kubectl port-forward svc/kiali -n istio-system 20001:20001

# Open in browser: http://localhost:20001
```

## Step 7: Create Chaos Testing Scenarios

### 7.1 Fault Injection - Delay

```bash
# Create delay for user jason
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ratings
spec:
  hosts:
  - ratings
  http:
  - match:
    - headers:
        end-user:
          exact: jason
    fault:
      delay:
        percentage:
          value: 100.0
        fixedDelay: 7s
    route:
    - destination:
        host: ratings
        subset: v1
  - route:
    - destination:
        host: ratings
        subset: v1
EOF
```

### 7.2 Fault Injection - Abort

```bash
# Create HTTP 500 errors
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ratings
spec:
  hosts:
  - ratings
  http:
  - match:
    - headers:
        end-user:
          exact: jason
    fault:
      abort:
        percentage:
          value: 100.0
        httpStatus: 500
    route:
    - destination:
        host: ratings
        subset: v1
  - route:
    - destination:
        host: ratings
        subset: v1
EOF
```

### 7.3 Circuit Breaking

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: reviews
spec:
  host: reviews
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 1
      http:
        http1MaxPendingRequests: 1
        http2MaxRequests: 1
    outlierDetection:
      consecutiveErrors: 1
      interval: 1s
      baseEjectionTime: 3m
      maxEjectionPercent: 100
      minHealthPercent: 0
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
  - name: v3
    labels:
      version: v3
EOF
```

## Step 8: Generate Load and Test

### 8.1 Create Load Testing Pod

```bash
# Deploy fortio for load testing
kubectl apply -f samples/httpbin/sample-client/fortio-deploy.yaml

# Get fortio pod name
export FORTIO_POD=$(kubectl get pods -l app=fortio -o jsonpath='{.items[0].metadata.name}')
```

### 8.2 Generate Normal Traffic

```bash
# Generate load to see normal behavior
kubectl exec $FORTIO_POD -c fortio -- /usr/bin/fortio load -c 2 -qps 10 -n 20 -loglevel Warning http://productpage:9080/productpage

# For circuit breaker testing
kubectl exec $FORTIO_POD -c fortio -- /usr/bin/fortio load -c 3 -qps 10 -n 30 -loglevel Warning http://reviews:9080/reviews/0
```

### 8.3 Test with Different Users

```bash
# Test as jason (will get delays/errors based on your config)
curl -H "end-user: jason" http://$INGRESS_HOST/productpage

# Test as other user (normal behavior)
curl http://$INGRESS_HOST/productpage
```

## Step 9: CloudWatch Integration

### 9.1 Install CloudWatch Container Insights

```bash
# Create namespace
kubectl create namespace amazon-cloudwatch

# Deploy CloudWatch agent and Fluentd
ClusterName=$CLUSTER_NAME
RegionName=$REGION
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'

curl https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluent-bit-quickstart.yaml | sed 's/{{cluster_name}}/'${ClusterName}'/;s/{{region_name}}/'${RegionName}'/;s/{{http_server_port}}/'${FluentBitHttpPort}'/;s/{{read_from_head}}/'${FluentBitReadFromHead}'/;s/{{read_from_tail}}/'${FluentBitReadFromTail}'/' | kubectl apply -f -
```

### 9.2 Create CloudWatch Dashboard

```bash
# Go to CloudWatch Console and create a new dashboard
# Add widgets for:
# - EKS cluster metrics
# - Istio metrics (if using Prometheus integration)
# - Application logs
```

## Step 10: Cleanup

```bash
# Delete chaos configurations
kubectl delete virtualservice ratings
kubectl delete destinationrule reviews

# Delete Bookinfo
kubectl delete -f samples/bookinfo/platform/kube/bookinfo.yaml
kubectl delete -f samples/bookinfo/networking/bookinfo-gateway.yaml

# Delete Istio
istioctl uninstall --purge -y
kubectl delete namespace istio-system

# Delete Load Balancer Controller
helm uninstall aws-load-balancer-controller -n kube-system

# Delete the cluster (if using eksctl)
eksctl delete cluster --name istio-chaos-lab --region us-east-1
```

## Troubleshooting Commands

```bash
# Check pod logs
kubectl logs <pod-name> -c istio-proxy

# Check Istio configuration
istioctl analyze

# Check sidecar injection
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].name}{"\n"}{end}'

# Debug service mesh
istioctl proxy-config cluster <pod-name>
istioctl proxy-config listeners <pod-name>

# Check Load Balancer Controller logs
kubectl logs -n kube-system deployment/aws-load-balancer-controller
```

## Tips for Manual Setup

1. **Always verify each step** before moving to the next
2. **Check pod status** with `kubectl get pods -A` frequently
3. **Monitor logs** if something fails: `kubectl logs <pod> -n <namespace>`
4. **DNS propagation** can take 5-15 minutes for Route53
5. **Keep terminal sessions organized** - use multiple tabs/windows
6. **Save your configurations** in files for easy reapplication
