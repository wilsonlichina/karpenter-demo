#!/bin/bash
set -e

# Set variables
export S3_BUCKET_NAME="business-card-email-extractor"
export NAMESPACE="email-extractor"
export CLUSTER_NAME="my-cc-cluster"
export AWS_REGION="$(aws configure get region)"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export IMAGE_NAME="email-extractor"
export IMAGE_TAG="latest"
export ECR_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${IMAGE_NAME}"

echo "Deploying Email Extractor application..."
echo "S3 Bucket: $S3_BUCKET_NAME"
echo "AWS Account ID: $AWS_ACCOUNT_ID"
echo "Cluster: $CLUSTER_NAME"

# Ensure we're connected to the right cluster
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

# Create or ensure ECR repository exists
echo "Creating ECR repository if it doesn't exist..."
aws ecr describe-repositories --repository-names $IMAGE_NAME --region $AWS_REGION || \
  aws ecr create-repository --repository-name $IMAGE_NAME --region $AWS_REGION

# Log in to ECR
echo "Logging in to ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Build and push multi-architecture Docker image
echo "Setting up Docker buildx for multi-architecture builds..."
# Remove existing builder if exists
docker buildx rm multiarch-builder 2>/dev/null || true
# Create a new builder instance
docker buildx create --name multiarch-builder --use

echo "Building and pushing multi-architecture image..."
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ${ECR_REPO}:${IMAGE_TAG} \
  --push \
  .

# Clean up builder
docker buildx rm multiarch-builder

# Apply Kubernetes configurations with variable substitution
echo "Applying Kubernetes configurations..."

# Create namespace if it doesn't exist
kubectl apply -f k8s/namespace.yaml

# Apply persistent volume and claim
kubectl apply -f k8s/persistent-volume.yaml
kubectl apply -f k8s/persistent-volume-claim.yaml

# Update deployment with actual AWS account ID and bucket name
cat k8s/deployment.yaml | \
  sed "s|\${AWS_ACCOUNT_ID}|$AWS_ACCOUNT_ID|g" | \
  sed "s|\${AWS_REGION}|$AWS_REGION|g" | \
  sed "s|\${S3_BUCKET_NAME}|$S3_BUCKET_NAME|g" | \
  kubectl apply -f -

# Apply service
kubectl apply -f k8s/service.yaml

# Apply ingress
kubectl apply -f k8s/ingress.yaml

echo "Deployment complete!"
echo "Check deployment status: kubectl get all -n $NAMESPACE"
echo "View logs: kubectl logs -n $NAMESPACE deployment/email-extractor"
echo "Access the application through the ALB at the /email-extractor path"
