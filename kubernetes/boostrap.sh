#!/bin/bash

# 1. Install AWS Load Balancer Controller
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://alb-policy.json

# Create Server Account with IAM Role
CLUSTER_NAME=chaos-engineering-eks-al2023
REGION=us-east-1
OIDC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)
aws iam list-open-id-connect-providers | grep $OIDC_ID

eksctl utils associate-iam-oidc-provider --cluster=$CLUSTER_NAME --region=$REGION --approve

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AWSLoadBalancerControllerIAMPolicy \
  --approve \
  --region=$REGION \
  --override-existing-serviceaccounts

# Install ALB Controller
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$REGION

kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get pods -n kube-system | grep aws-load-balancer

# Install Istio
istioctl install --set profile=demo -y
kubectl get pods -n istio-system
kubectl get svc -n istio-system
kubectl label namespace default istio-injection=enabled

# Configure Istio Gateway with Existing ACM Certificate
aws acm list-certificates --region $REGION
>> edit istio-nlb-patch.yaml and replace with your ACM cert ARN
kubectl patch svc istio-ingressgateway -n istio-system --patch-file istio-nlb-patch.yaml

# Get LoadBalancer DNS
kubectl get svc istio-ingressgateway -n istio-system -w
>> In the meantime, you can update your route53 to add an alias to bookinfo.yourdomain.com to the nlb

# Deploy Bookinfo Application
kubectl apply -f bookinfo/platform/kube/bookinfo.yaml
kubectl get pods -w
kubectl get svc

# Apply Gateway an VirtualService
kubectl apply -f bookinfo-gw.yaml
kubectl apply -f bookinfo/networking/bookinfo-gateway.yaml

# Install Addons
kubectl apply -f addons/prometheus.yaml
kubectl apply -f addons/grafana.yaml
kubectl apply -f addons/jaeger.yaml
kubectl apply -f addons/kiali.yaml

# Set CloudWatch Monitoring
kubectl create namespace amazon-cloudwatch

ClusterName=$CLUSTER_NAME
RegionName=$REGION
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'

curl https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluent-bit-quickstart.yaml | sed 's/{{cluster_name}}/'${ClusterName}'/;s/{{region_name}}/'${RegionName}'/;s/{{http_server_port}}/'${FluentBitHttpPort}'/;s/{{read_from_head}}/'${FluentBitReadFromHead}'/;s/{{read_from_tail}}/'${FluentBitReadFromTail}'/' | kubectl apply -f -
