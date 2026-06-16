#!/usr/bin/env bash
# Tears down all resources created by aws-setup.sh.
# Usage: bash aws-teardown.sh [cluster-name] [region]
set -euo pipefail

CLUSTER_NAME="${1:-cnpg-benchmark}"
REGION="${2:-us-east-1}"
IAM_USER="${CLUSTER_NAME}-s3"
POLICY_NAME="${CLUSTER_NAME}-s3-policy"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
BUCKETS=("${CLUSTER_NAME}-barman" "${CLUSTER_NAME}-opera" "${CLUSTER_NAME}-dalibo")

echo "=== cnpg benchmark AWS teardown ==="
echo "Cluster : $CLUSTER_NAME"
echo "Region  : $REGION"
echo ""

echo "Deleting EKS cluster (this takes ~10 minutes)..."
eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" || true

echo ""
echo "Emptying and deleting S3 buckets..."
for BUCKET in "${BUCKETS[@]}"; do
  aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null && echo "  emptied: $BUCKET" || true
  aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null \
    && echo "  deleted: $BUCKET" || echo "  not found: $BUCKET"
done

echo ""
echo "Removing IAM resources..."
# Delete all access keys for the benchmark user
for KEY in $(aws iam list-access-keys --user-name "$IAM_USER" \
             --query 'AccessKeyMetadata[*].AccessKeyId' --output text 2>/dev/null); do
  aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$KEY"
  echo "  deleted key: $KEY"
done
aws iam detach-user-policy --user-name "$IAM_USER" --policy-arn "$POLICY_ARN" 2>/dev/null || true
aws iam delete-user --user-name "$IAM_USER" 2>/dev/null \
  && echo "  deleted user: $IAM_USER" || echo "  user not found"
# Delete all non-default policy versions first, then the policy itself
for VER in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
             --query 'Versions[?!IsDefaultVersion].VersionId' --output text 2>/dev/null); do
  aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$VER" 2>/dev/null || true
done
aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null \
  && echo "  deleted policy: $POLICY_NAME" || echo "  policy not found"

# No EBS CSI role to delete — cluster uses local NVMe storage, not EBS.

echo ""
echo "Teardown complete."
