#!/usr/bin/env bash
# Install/upgrade the AWS Load Balancer Controller (required by k8s/ingress.yaml) using the
# IRSA role created by Terraform. Run with cluster-admin credentials (not the Jenkins role).
#
#   ./scripts/install-lb-controller.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tf() { terraform -chdir="$REPO_ROOT/terraform" output -raw "$1"; }

CLUSTER_NAME="$(tf eks_cluster_name)"
ROLE_ARN="$(tf aws_lbc_role_arn)"
VPC_ID="$(tf vpc_id)"
REGION="${AWS_REGION:-ap-south-1}"

helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN" \
  --wait --timeout 5m

kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=3m
