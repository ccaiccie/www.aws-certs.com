#!/bin/bash

# EKS Cluster Cleanup Script
# This script removes all resources created by the EKS setup script

set -e  # Exit on any error

# Check if cluster-resources.env exists
if [ ! -f "cluster-resources.env" ]; then
    echo "Error: cluster-resources.env file not found!"
    echo "This file should have been created by the setup script."
    echo "Please ensure you're running this from the same directory as the setup script."
    exit 1
fi

# Source the resource information
echo "Loading cluster resource information..."
source cluster-resources.env

echo "========================================="
echo "EKS Cluster Cleanup Starting..."
echo "Cluster Name: $CLUSTER_NAME"
echo "Region: $REGION"
echo "========================================="

# Step 1: Delete Kubernetes resources
echo "Step 1: Deleting Kubernetes applications..."
if [ -f "test-app.yaml" ]; then
    kubectl delete -f test-app.yaml --ignore-not-found=true
    echo "Test application deleted"
else
    echo "test-app.yaml not found, skipping..."
fi

if [ -f "external-dns.yaml" ]; then
    kubectl delete -f external-dns.yaml --ignore-not-found=true
    echo "ExternalDNS deleted"
else
    echo "external-dns.yaml not found, skipping..."
fi

# Step 2: Uninstall Helm charts
echo "Step 2: Uninstalling Helm charts..."
helm uninstall aws-load-balancer-controller -n kube-system --ignore-not-found || echo "AWS Load Balancer Controller not found or already uninstalled"

# Step 3: Wait for load balancers to be cleaned up
echo "Step 3: Waiting for load balancers to be cleaned up..."
echo "This may take a few minutes as ExternalDNS and the Load Balancer Controller clean up AWS resources..."
sleep 30

# Check for any remaining load balancers
echo "Checking for remaining load balancers..."
LBS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName, '$CLUSTER_NAME') || contains(Tags[?Key=='kubernetes.io/cluster/$CLUSTER_NAME'].Value, 'owned')].LoadBalancerArn" --output text 2>/dev/null || echo "")
if [ ! -z "$LBS" ]; then
    echo "Warning: Found load balancers that may be associated with this cluster:"
    echo "$LBS"
    echo "Waiting additional time for cleanup..."
    sleep 60
fi

# Step 4: Delete EKS Node Group
echo "Step 4: Deleting EKS node group..."
if aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $NODE_GROUP_NAME >/dev/null 2>&1; then
    echo "Deleting node group: $NODE_GROUP_NAME"
    aws eks delete-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $NODE_GROUP_NAME
    echo "Waiting for node group deletion to complete..."
    aws eks wait nodegroup-deleted --cluster-name $CLUSTER_NAME --nodegroup-name $NODE_GROUP_NAME
    echo "Node group deleted successfully"
else
    echo "Node group $NODE_GROUP_NAME not found or already deleted"
fi

# Step 5: Delete EKS Cluster
echo "Step 5: Deleting EKS cluster..."
if aws eks describe-cluster --name $CLUSTER_NAME >/dev/null 2>&1; then
    echo "Deleting cluster: $CLUSTER_NAME"
    aws eks delete-cluster --name $CLUSTER_NAME
    echo "Waiting for cluster deletion to complete..."
    aws eks wait cluster-deleted --name $CLUSTER_NAME
    echo "Cluster deleted successfully"
else
    echo "Cluster $CLUSTER_NAME not found or already deleted"
fi

# Step 6: Delete IAM roles and policies
echo "Step 6: Cleaning up IAM roles and policies..."

# Clean up cluster role
echo "Deleting cluster IAM role..."
aws iam detach-role-policy --role-name ${CLUSTER_NAME}-cluster-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy 2>/dev/null || echo "Policy already detached"
aws iam delete-role --role-name ${CLUSTER_NAME}-cluster-role 2>/dev/null || echo "Role already deleted"

# Clean up node role
echo "Deleting node group IAM role..."
aws iam detach-role-policy --role-name ${CLUSTER_NAME}-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy 2>/dev/null || echo "Policy already detached"
aws iam detach-role-policy --role-name ${CLUSTER_NAME}-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy 2>/dev/null || echo "Policy already detached"
aws iam detach-role-policy --role-name ${CLUSTER_NAME}-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly 2>/dev/null || echo "Policy already detached"
aws iam delete-role --role-name ${CLUSTER_NAME}-node-role 2>/dev/null || echo "Role already deleted"

# Clean up Load Balancer Controller role and policy
echo "Deleting AWS Load Balancer Controller IAM resources..."
aws iam detach-role-policy --role-name AmazonEKSLoadBalancerControllerRole-${CLUSTER_NAME} --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME} 2>/dev/null || echo "Policy already detached"
aws iam delete-role --role-name AmazonEKSLoadBalancerControllerRole-${CLUSTER_NAME} 2>/dev/null || echo "Role already deleted"
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME} 2>/dev/null || echo "Policy already deleted"

# Clean up ExternalDNS role and policy
echo "Deleting ExternalDNS IAM resources..."
aws iam detach-role-policy --role-name ExternalDNSRole-${CLUSTER_NAME} --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/ExternalDNSPolicy-${CLUSTER_NAME} 2>/dev/null || echo "Policy already detached"
aws iam delete-role --role-name ExternalDNSRole-${CLUSTER_NAME} 2>/dev/null || echo "Role already deleted"
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/ExternalDNSPolicy-${CLUSTER_NAME} 2>/dev/null || echo "Policy already deleted"

# Step 7: Delete OIDC Identity Provider
echo "Step 7: Deleting OIDC Identity Provider..."
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null | sed 's|https://||' || echo '')"
if [ ! -z "$OIDC_PROVIDER_ARN" ] && [ "$OIDC_PROVIDER_ARN" != "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/" ]; then
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn $OIDC_PROVIDER_ARN 2>/dev/null || echo "OIDC provider already deleted or not found"
else
    echo "OIDC provider not found or already deleted"
fi

# Step 8: Wait for ENIs to be cleaned up
echo "Step 8: Waiting for network interfaces to be cleaned up..."
echo "Checking for ENIs in subnets..."
sleep 30

# Check for ENIs in our subnets and wait for them to be cleaned up
for subnet in $SUBNET1_ID $SUBNET2_ID; do
    ENI_COUNT=$(aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=$subnet" --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo "0")
    if [ "$ENI_COUNT" -gt "0" ]; then
        echo "Waiting for $ENI_COUNT network interfaces in subnet $subnet to be cleaned up..."
        sleep 60
    fi
done

# Step 9: Delete VPC and networking components
echo "Step 9: Deleting VPC and networking components..."

# Get route table associations and delete them
echo "Deleting route table associations..."
ASSOCIATIONS=$(aws ec2 describe-route-tables --route-table-ids $ROUTE_TABLE_ID --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null || echo "")
for assoc in $ASSOCIATIONS; do
    if [ ! -z "$assoc" ] && [ "$assoc" != "None" ]; then
        aws ec2 disassociate-route-table --association-id $assoc 2>/dev/null || echo "Association $assoc already removed"
    fi
done

# Delete route to internet gateway
echo "Deleting routes..."
aws ec2 delete-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 2>/dev/null || echo "Route already deleted"

# Delete route table
echo "Deleting route table..."
aws ec2 delete-route-table --route-table-id $ROUTE_TABLE_ID 2>/dev/null || echo "Route table already deleted"

# Delete subnets
echo "Deleting subnets..."
aws ec2 delete-subnet --subnet-id $SUBNET1_ID 2>/dev/null || echo "Subnet $SUBNET1_ID already deleted"
aws ec2 delete-subnet --subnet-id $SUBNET2_ID 2>/dev/null || echo "Subnet $SUBNET2_ID already deleted"

# Delete security group
echo "Deleting security group..."
aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID 2>/dev/null || echo "Security group already deleted"

# Detach and delete internet gateway
echo "Deleting internet gateway..."
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID 2>/dev/null || echo "Internet gateway already detached"
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID 2>/dev/null || echo "Internet gateway already deleted"

# Delete VPC
echo "Deleting VPC..."
aws ec2 delete-vpc --vpc-id $VPC_ID 2>/dev/null || echo "VPC already deleted"

# Step 10: Clean up local files
echo "Step 10: Cleaning up local files..."
rm -f cluster-resources.env
rm -f test-app.yaml
rm -f external-dns.yaml
echo "Local configuration files cleaned up"

echo "========================================="
echo "EKS Cluster Cleanup Complete!"
echo "========================================="
echo "All resources have been deleted."
echo "Please verify in the AWS Console that no resources remain."
echo ""
echo "Note: DNS records in Route 53 may take some time to be removed"
echo "by ExternalDNS. Check your hosted zone if needed."
echo "========================================="
