#!/bin/bash

# EKS Cluster Setup with DNS and Route 53 Integration
# This script creates a complete EKS environment for testing DNS integration

set -e  # Exit on any error

# Configuration Variables
CLUSTER_NAME="dns-test-cluster"
REGION="us-west-1"
NODE_GROUP_NAME="dns-test-nodes"
DOMAIN_NAME="example.com"  # Change this to your domain
SUBDOMAIN="eks-test"       # Will create eks-test.example.com
VPC_CIDR="10.0.0.0/16"
SUBNET1_CIDR="10.0.1.0/24"
SUBNET2_CIDR="10.0.2.0/24"

echo "========================================="
echo "EKS DNS Integration Setup Starting..."
echo "Cluster Name: $CLUSTER_NAME"
echo "Region: $REGION"
echo "Domain: $SUBDOMAIN.$DOMAIN_NAME"
echo "========================================="

# Step 1: Create IAM Role for EKS Cluster
echo "Step 1: Creating EKS Cluster Service Role..."
aws iam create-role \
    --role-name ${CLUSTER_NAME}-cluster-role \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Service": "eks.amazonaws.com"
                },
                "Action": "sts:AssumeRole"
            }
        ]
    }' \
    --description "EKS cluster service role for ${CLUSTER_NAME}"

# Attach required policies to the cluster role
echo "Attaching EKS cluster policies..."
aws iam attach-role-policy \
    --role-name ${CLUSTER_NAME}-cluster-role \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

# Step 2: Create IAM Role for EKS Node Group
echo "Step 2: Creating EKS Node Group Role..."
aws iam create-role \
    --role-name ${CLUSTER_NAME}-node-role \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Service": "ec2.amazonaws.com"
                },
                "Action": "sts:AssumeRole"
            }
        ]
    }' \
    --description "EKS node group role for ${CLUSTER_NAME}"

# Attach required policies to the node group role
echo "Attaching EKS node group policies..."
aws iam attach-role-policy \
    --role-name ${CLUSTER_NAME}-node-role \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

aws iam attach-role-policy \
    --role-name ${CLUSTER_NAME}-node-role \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy

aws iam attach-role-policy \
    --role-name ${CLUSTER_NAME}-node-role \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

# Step 3: Create VPC and Networking Components
echo "Step 3: Creating VPC and networking components..."

# Create VPC
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $VPC_CIDR \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${CLUSTER_NAME}-vpc}]" \
    --query 'Vpc.VpcId' \
    --output text)
echo "Created VPC: $VPC_ID"

# Enable DNS hostnames and resolution for the VPC (required for EKS)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support

# Create Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${CLUSTER_NAME}-igw}]" \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)
echo "Created Internet Gateway: $IGW_ID"

# Attach Internet Gateway to VPC
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# Get availability zones
AZ1=$(aws ec2 describe-availability-zones --region $REGION --query 'AvailabilityZones[0].ZoneName' --output text)
AZ2=$(aws ec2 describe-availability-zones --region $REGION --query 'AvailabilityZones[1].ZoneName' --output text)

# Create public subnets in different AZs (EKS requires at least 2 AZs)
SUBNET1_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $SUBNET1_CIDR \
    --availability-zone $AZ1 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-subnet-1},{Key=kubernetes.io/role/elb,Value=1}]" \
    --query 'Subnet.SubnetId' \
    --output text)
echo "Created Subnet 1: $SUBNET1_ID in $AZ1"

SUBNET2_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $SUBNET2_CIDR \
    --availability-zone $AZ2 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-subnet-2},{Key=kubernetes.io/role/elb,Value=1}]" \
    --query 'Subnet.SubnetId' \
    --output text)
echo "Created Subnet 2: $SUBNET2_ID in $AZ2"

# Enable auto-assign public IP for subnets
aws ec2 modify-subnet-attribute --subnet-id $SUBNET1_ID --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $SUBNET2_ID --map-public-ip-on-launch

# Create Route Table
ROUTE_TABLE_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${CLUSTER_NAME}-rt}]" \
    --query 'RouteTable.RouteTableId' \
    --output text)
echo "Created Route Table: $ROUTE_TABLE_ID"

# Add route to Internet Gateway
aws ec2 create-route \
    --route-table-id $ROUTE_TABLE_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $IGW_ID

# Associate subnets with route table
aws ec2 associate-route-table --subnet-id $SUBNET1_ID --route-table-id $ROUTE_TABLE_ID
aws ec2 associate-route-table --subnet-id $SUBNET2_ID --route-table-id $ROUTE_TABLE_ID

# Step 4: Create Security Group for EKS
echo "Step 4: Creating Security Group..."
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name ${CLUSTER_NAME}-sg \
    --description "Security group for EKS cluster ${CLUSTER_NAME}" \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${CLUSTER_NAME}-sg}]" \
    --query 'GroupId' \
    --output text)
echo "Created Security Group: $SECURITY_GROUP_ID"

# Add ingress rules for HTTP/HTTPS (for testing web services)
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 443 \
    --cidr 0.0.0.0/0

# Step 5: Wait for IAM roles to propagate
echo "Step 5: Waiting for IAM roles to propagate..."
sleep 10

# Get account ID for constructing ARNs
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

# Step 6: Create EKS Cluster
echo "Step 6: Creating EKS Cluster..."
aws eks create-cluster \
    --name $CLUSTER_NAME \
    --version 1.28 \
    --role-arn arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-cluster-role \
    --resources-vpc-config subnetIds=${SUBNET1_ID},${SUBNET2_ID},securityGroupIds=${SECURITY_GROUP_ID} \
    --endpoint-config privateAccess=true,publicAccess=true \
    --logging '{"enable":[{"types":["api","audit","authenticator","controllerManager","scheduler"]}]}' \
    --tags Name=${CLUSTER_NAME}

echo "Cluster creation initiated. Waiting for cluster to become active..."

# Wait for cluster to be active (this can take 10-15 minutes)
aws eks wait cluster-active --name $CLUSTER_NAME
echo "EKS Cluster is now active!"

# Step 7: Update kubeconfig
echo "Step 7: Updating kubeconfig..."
aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME

# Step 8: Create Node Group
echo "Step 8: Creating EKS Node Group..."
aws eks create-nodegroup \
    --cluster-name $CLUSTER_NAME \
    --nodegroup-name $NODE_GROUP_NAME \
    --scaling-config minSize=1,maxSize=3,desiredSize=2 \
    --disk-size 20 \
    --instance-types t3.medium \
    --ami-type AL2_x86_64 \
    --node-role arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-node-role \
    --subnets $SUBNET1_ID $SUBNET2_ID \
    --tags Name=${NODE_GROUP_NAME}

echo "Node group creation initiated. Waiting for node group to become active..."
aws eks wait nodegroup-active --cluster-name $CLUSTER_NAME --nodegroup-name $NODE_GROUP_NAME
echo "Node group is now active!"

# Step 9: Install AWS Load Balancer Controller
echo "Step 9: Installing AWS Load Balancer Controller..."

# Create IAM role for AWS Load Balancer Controller
cat > aws-load-balancer-controller-trust-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||')"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||'):sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
                    "$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||'):aud": "sts.amazonaws.com"
                }
            }
        }
    ]
}
EOF

# Create the OIDC identity provider for the cluster
OIDC_ISSUER=$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.identity.oidc.issuer' --output text)
OIDC_ID=$(echo $OIDC_ISSUER | sed 's|https://||')

# Check if OIDC provider already exists
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ID} >/dev/null 2>&1; then
    # Get the thumbprint
    THUMBPRINT=$(echo | openssl s_client -servername $OIDC_ID -connect $OIDC_ID:443 2>/dev/null | openssl x509 -fingerprint -noout -sha1 | sed 's/://g' | sed 's/SHA1 Fingerprint=//' | tr '[:upper:]' '[:lower:]')
    
    aws iam create-open-id-connect-provider \
        --url $OIDC_ISSUER \
        --client-id-list sts.amazonaws.com \
        --thumbprint-list $THUMBPRINT
fi

# Download and apply AWS Load Balancer Controller IAM policy
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.6.3/docs/install/iam_policy.json

aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME} \
    --policy-document file://iam-policy.json || echo "Policy might already exist"

# Create IAM role for the controller
aws iam create-role \
    --role-name AmazonEKSLoadBalancerControllerRole-${CLUSTER_NAME} \
    --assume-role-policy-document file://aws-load-balancer-controller-trust-policy.json

aws iam attach-role-policy \
    --role-name AmazonEKSLoadBalancerControllerRole-${CLUSTER_NAME} \
    --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}

# Install AWS Load Balancer Controller using Helm
echo "Installing AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts || echo "Helm repo might already exist"
helm repo update

kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller//crds?ref=master"

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=$CLUSTER_NAME \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set region=$REGION \
    --set vpcId=$VPC_ID

# Create service account with IAM role annotation
kubectl create serviceaccount aws-load-balancer-controller -n kube-system || echo "Service account might already exist"
kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system \
    eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKSLoadBalancerControllerRole-${CLUSTER_NAME}

# Step 10: Install ExternalDNS for Route 53 Integration
echo "Step 10: Installing ExternalDNS for Route 53..."

# Create IAM policy for ExternalDNS
cat > external-dns-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "route53:ChangeResourceRecordSets"
            ],
            "Resource": [
                "arn:aws:route53:::hostedzone/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "route53:ListHostedZones",
                "route53:ListResourceRecordSets"
            ],
            "Resource": [
                "*"
            ]
        }
    ]
}
EOF

aws iam create-policy \
    --policy-name ExternalDNSPolicy-${CLUSTER_NAME} \
    --policy-document file://external-dns-policy.json || echo "Policy might already exist"

# Create trust policy for ExternalDNS
cat > external-dns-trust-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ID}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${OIDC_ID}:sub": "system:serviceaccount:kube-system:external-dns",
                    "${OIDC_ID}:aud": "sts.amazonaws.com"
                }
            }
        }
    ]
}
EOF

# Create IAM role for ExternalDNS
aws iam create-role \
    --role-name ExternalDNSRole-${CLUSTER_NAME} \
    --assume-role-policy-document file://external-dns-trust-policy.json

aws iam attach-role-policy \
    --role-name ExternalDNSRole-${CLUSTER_NAME} \
    --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/ExternalDNSPolicy-${CLUSTER_NAME}

# Deploy ExternalDNS
cat > external-dns.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-dns
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${ACCOUNT_ID}:role/ExternalDNSRole-${CLUSTER_NAME}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: external-dns
rules:
- apiGroups: [""]
  resources: ["services","endpoints","pods"]
  verbs: ["get","watch","list"]
- apiGroups: ["extensions","networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get","watch","list"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: external-dns-viewer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: external-dns
subjects:
- kind: ServiceAccount
  name: external-dns
  namespace: kube-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: external-dns
  namespace: kube-system
spec:
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: external-dns
  template:
    metadata:
      labels:
        app: external-dns
    spec:
      serviceAccountName: external-dns
      containers:
      - name: external-dns
        image: k8s.gcr.io/external-dns/external-dns:v0.13.6
        args:
        - --source=service
        - --source=ingress
        - --domain-filter=${DOMAIN_NAME}
        - --provider=aws
        - --aws-zone-type=public
        - --registry=txt
        - --txt-owner-id=${CLUSTER_NAME}
      securityContext:
        fsGroup: 65534
EOF

kubectl apply -f external-dns.yaml

# Step 11: Create a test application
echo "Step 11: Creating test application..."
cat > test-app.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
      initContainers:
      - name: html-generator
        image: busybox
        command: ['sh', '-c', 'echo "<h1>EKS DNS Test</h1><p>Pod: \$POD_NAME</p><p>IP: \$POD_IP</p><p>Hostname: \$(hostname)</p>" > /html/index.html']
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        volumeMounts:
        - name: html
          mountPath: /html
      volumes:
      - name: html
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-test-service
  namespace: default
  annotations:
    external-dns.alpha.kubernetes.io/hostname: ${SUBDOMAIN}.${DOMAIN_NAME}
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
spec:
  type: LoadBalancer
  selector:
    app: nginx-test
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-test-ingress
  namespace: default
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    external-dns.alpha.kubernetes.io/hostname: ingress.${SUBDOMAIN}.${DOMAIN_NAME}
spec:
  rules:
  - host: ingress.${SUBDOMAIN}.${DOMAIN_NAME}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx-test-service
            port:
              number: 80
EOF

kubectl apply -f test-app.yaml

# Step 12: Save resource IDs for cleanup
echo "Step 12: Saving resource information for cleanup..."
cat > cluster-resources.env <<EOF
# EKS Cluster Resource Information
# Source this file before running cleanup: source cluster-resources.env

export CLUSTER_NAME="$CLUSTER_NAME"
export REGION="$REGION"
export NODE_GROUP_NAME="$NODE_GROUP_NAME"
export DOMAIN_NAME="$DOMAIN_NAME"
export SUBDOMAIN="$SUBDOMAIN"
export VPC_ID="$VPC_ID"
export SUBNET1_ID="$SUBNET1_ID"
export SUBNET2_ID="$SUBNET2_ID"
export SECURITY_GROUP_ID="$SECURITY_GROUP_ID"
export IGW_ID="$IGW_ID"
export ROUTE_TABLE_ID="$ROUTE_TABLE_ID"
export ACCOUNT_ID="$ACCOUNT_ID"
EOF

echo "Resource information saved to cluster-resources.env"

# Clean up temporary files
rm -f aws-load-balancer-controller-trust-policy.json
rm -f iam-policy.json
rm -f external-dns-policy.json
rm -f external-dns-trust-policy.json

echo "========================================="
echo "EKS Cluster Setup Complete!"
echo "========================================="
echo "Cluster Name: $CLUSTER_NAME"
echo "Region: $REGION"
echo "VPC ID: $VPC_ID"
echo "Subnet IDs: $SUBNET1_ID, $SUBNET2_ID"
echo ""
echo "Test your setup:"
echo "1. Check cluster status: kubectl get nodes"
echo "2. Check services: kubectl get svc"
echo "3. Check ingresses: kubectl get ingress"
echo "4. Check ExternalDNS logs: kubectl logs -n kube-system -l app=external-dns"
echo ""
echo "Your test application will be available at:"
echo "- Service: ${SUBDOMAIN}.${DOMAIN_NAME} (after DNS propagation)"
echo "- Ingress: ingress.${SUBDOMAIN}.${DOMAIN_NAME} (after DNS propagation)"
echo ""
echo "To clean up everything, create a separate cleanup script that sources cluster-resources.env"
echo "========================================="
