#!/usr/bin/env bash
# Creates the AWS resources needed for the cnpg plugin benchmark.
# Writes all credentials to ./<cluster-name>-creds.env (chmod 600).
# Run this once. Tear down with aws-teardown.sh.
#
# Requirements: aws CLI configured with admin credentials, kubectl, eksctl
# Usage: bash aws-setup.sh [cluster-name] [region]
#
# Node type: must have local NVMe and be x86_64. c6id family works
# Storage: local-path-provisioner (rancher) backed by the NVMe instance store.
# Multiple PVCs share the single NVMe disk via subdirectory provisioning —
# no quotas, no size enforcement, no LVM. All three benchmark clusters fit on
# one node. Backups go to S3 over the network.
set -euo pipefail

CLUSTER_NAME="${1:-cnpg1}"
REGION="${2:-us-east-1}"
CREDS_FILE="$(dirname "$0")/${CLUSTER_NAME}-creds.env"
KUBECONFIG_FILE="$(dirname "$0")/${CLUSTER_NAME}-kubeconfig.yaml"
#NODE_TYPE="m6id.xlarge"   # for testing. make sure to use x86_64
NODE_TYPE="c6id.32xlarge"
NODE_COUNT=1
K8S_VERSION="1.35"
IAM_USER="${CLUSTER_NAME}-s3"
BUCKETS=("${CLUSTER_NAME}-barman" "${CLUSTER_NAME}-opera" "${CLUSTER_NAME}-dalibo")

echo "=== cnpg benchmark AWS setup ==="
echo "Cluster : $CLUSTER_NAME"
echo "Region  : $REGION"
echo "Nodes   : $NODE_COUNT x $NODE_TYPE (local NVMe)"
echo ""

# ── S3 buckets ────────────────────────────────────────────────────────────────
echo "Creating S3 buckets..."
for BUCKET in "${BUCKETS[@]}"; do
  if [ "$REGION" = "us-east-1" ]; then
    BUCKET_ARGS=(--bucket "$BUCKET" --region "$REGION")
  else
    BUCKET_ARGS=(--bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION")
  fi
  if CMD_OUT=$(aws s3api create-bucket "${BUCKET_ARGS[@]}" 2>&1); then
    echo "  created: $BUCKET"
  elif echo "$CMD_OUT" | grep -q "BucketAlreadyOwnedByYou"; then
    echo "  exists:  $BUCKET"
  else
    echo "  ERROR creating $BUCKET: $CMD_OUT" >&2
    exit 1
  fi
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
done

# ── IAM user + policy ─────────────────────────────────────────────────────────
echo ""
echo "Creating IAM user $IAM_USER..."
aws iam create-user --user-name "$IAM_USER" 2>/dev/null \
  && echo "  created" || echo "  already exists"

POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::${CLUSTER_NAME}-barman",
        "arn:aws:s3:::${CLUSTER_NAME}-barman/*",
        "arn:aws:s3:::${CLUSTER_NAME}-opera",
        "arn:aws:s3:::${CLUSTER_NAME}-opera/*",
        "arn:aws:s3:::${CLUSTER_NAME}-dalibo",
        "arn:aws:s3:::${CLUSTER_NAME}-dalibo/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "eks:GetToken"
      ],
      "Resource": "arn:aws:eks:*:*:cluster/${CLUSTER_NAME}"
    }
  ]
}
EOF
)

POLICY_NAME="${CLUSTER_NAME}-s3-policy"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document "$POLICY_DOC" 2>/dev/null \
  && echo "  policy created" || echo "  policy already exists"

aws iam attach-user-policy \
  --user-name "$IAM_USER" \
  --policy-arn "$POLICY_ARN"
echo "  policy attached"

echo ""
echo "Creating IAM access key..."
KEY_JSON=$(aws iam create-access-key --user-name "$IAM_USER")
ACCESS_KEY_ID=$(echo "$KEY_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['AccessKeyId'])")
SECRET_ACCESS_KEY=$(echo "$KEY_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['SecretAccessKey'])")

# ── EKS cluster ───────────────────────────────────────────────────────────────
echo ""
echo "Creating EKS cluster $CLUSTER_NAME (this takes ~15 minutes)..."
eksctl create cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --version "$K8S_VERSION" \
  --nodegroup-name benchmark-nodes \
  --node-type "$NODE_TYPE" \
  --nodes "$NODE_COUNT" \
  --nodes-min "$NODE_COUNT" \
  --nodes-max "$NODE_COUNT" \
  --managed

echo ""
echo "Fetching kubeconfig..."
aws eks update-kubeconfig \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --kubeconfig "$KUBECONFIG_FILE"

export KUBECONFIG="$KUBECONFIG_FILE"

# ── Grant benchmark IAM user access to the cluster ───────────────────────────
# The cluster was created with admin credentials. The benchmark IAM user
# ($IAM_USER) needs to be mapped into the cluster's aws-auth ConfigMap
# so kubectl works with the benchmark credentials from any machine.
echo ""
echo "Granting cluster access to IAM user $IAM_USER..."
eksctl create iamidentitymapping \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --arn "arn:aws:iam::${ACCOUNT_ID}:user/${IAM_USER}" \
  --username "$IAM_USER" \
  --group system:masters
echo "  IAM identity mapping created"

# ── NVMe DaemonSet ────────────────────────────────────────────────────────────
# Formats the NVMe instance store disk and mounts it to /mnt/nvme on every
# node. Uses nvme list to detect the instance store device reliably (avoids
# hardcoding device names which are not stable across boots).
# Mounts only /mnt on the host to avoid the container-rootfs conflict that
# occurs when mounting / inside a container.
echo ""
echo "Deploying NVMe format+mount DaemonSet..."
kubectl apply -f - <<'YAML'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvme-mount
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: nvme-mount
  template:
    metadata:
      labels:
        app: nvme-mount
    spec:
      priorityClassName: system-node-critical
      hostPID: true
      tolerations:
      - operator: Exists
      initContainers:
      - name: nvme-setup
        image: public.ecr.aws/amazonlinux/amazonlinux:2023
        securityContext:
          privileged: true
        command:
        - /bin/bash
        - -c
        - |
          set -euo pipefail
          yum install -y -q util-linux xfsprogs nvme-cli
          MOUNT=/mnt/nvme

          # Skip if already mounted
          if mountpoint -q "$MOUNT"; then
            echo "Already mounted at $MOUNT"
            exit 0
          fi

          # Detect instance store device by model string (stable across reboots)
          DEVICE=$(nvme list 2>/dev/null \
            | awk '/Amazon EC2 NVMe Instance Storage/ {print $1; exit}')

          if [ -z "$DEVICE" ]; then
            echo "No NVMe instance store found — skipping"
            exit 0
          fi
          echo "Instance store device: $DEVICE"

          # Format if no filesystem present
          if ! blkid "$DEVICE" &>/dev/null; then
            echo "Formatting $DEVICE as xfs..."
            mkfs.xfs -f "$DEVICE"
          fi

          mkdir -p "$MOUNT"
          mount -o defaults,noatime,nodiscard "$DEVICE" "$MOUNT"
          mkdir -p "$MOUNT/local-path-provisioner"
          chmod 0777 "$MOUNT/local-path-provisioner"
          echo "Mounted $DEVICE at $MOUNT"
        volumeMounts:
        - name: host-mnt
          mountPath: /mnt
          mountPropagation: Bidirectional
      containers:
      - name: pause
        image: public.ecr.aws/eks-distro/kubernetes/pause:3.9
        resources:
          requests:
            cpu: 1m
            memory: 1Mi
      volumes:
      - name: host-mnt
        hostPath:
          path: /mnt
          type: DirectoryOrCreate
YAML

echo "  Waiting for nvme-mount DaemonSet to be ready..."
kubectl rollout status daemonset/nvme-mount -n kube-system --timeout=120s

# ── local-path-provisioner ────────────────────────────────────────────────────
# Rancher local-path-provisioner dynamically creates one subdirectory per PVC
# under the base path. Multiple PVCs share the NVMe disk without quotas or
# size limits — exactly what the benchmark needs (three clusters, one disk).
echo ""
echo "Installing local-path-provisioner..."
kubectl apply -f \
  https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.34/deploy/local-path-storage.yaml

# Point the provisioner at the NVMe mount instead of the default /opt path
kubectl patch configmap local-path-config \
  -n local-path-storage \
  --type merge \
  -p '{"data":{"config.json":"{\"nodePathMap\":[{\"node\":\"DEFAULT_PATH_FOR_NON_LISTED_NODES\",\"paths\":[\"/mnt/nvme/local-path-provisioner\"]}]}"}}'

kubectl rollout status deployment/local-path-provisioner \
  -n local-path-storage --timeout=120s

# ── StorageClass ──────────────────────────────────────────────────────────────
echo ""
echo "Creating local-nvme StorageClass..."
kubectl apply -f - <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-nvme
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
YAML

# Remove default annotation from gp2 if present
kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
  2>/dev/null || true

echo "  StorageClass local-nvme set as default (rancher/local-path-provisioner)"

# ── Verify nodes and storage ──────────────────────────────────────────────────
echo ""
echo "Cluster nodes:"
kubectl get nodes -o wide --no-headers | awk '{print "  "$1, $2, $5, $6}'

echo ""
echo "Storage classes:"
kubectl get storageclass --no-headers | awk '{print "  "$1, $2}'

# ── Write credentials file ────────────────────────────────────────────────────
cat > "$CREDS_FILE" <<EOF
# cnpg benchmark credentials — generated by aws-setup.sh
# Source this file: source ${CLUSTER_NAME}-creds.env

export CLUSTER_NAME=${CLUSTER_NAME}
export REGION=${REGION}

export AWS_ACCESS_KEY_ID=${ACCESS_KEY_ID}
export AWS_SECRET_ACCESS_KEY=${SECRET_ACCESS_KEY}

export S3_BUCKET_BARMAN=${CLUSTER_NAME}-barman
export S3_BUCKET_OPERA=${CLUSTER_NAME}-opera
export S3_BUCKET_DALIBO=${CLUSTER_NAME}-dalibo

export KUBECONFIG=${KUBECONFIG_FILE}
EOF
chmod 600 "$CREDS_FILE"

echo ""
echo "========================================================"
echo "  Credentials written to: $CREDS_FILE"
echo "  Kubeconfig written to:  $KUBECONFIG_FILE"
echo "  Both files are chmod 600."
echo ""
echo "  Node storage    : local NVMe instance store ($NODE_TYPE, shared via local-path-provisioner)"
echo "  StorageClass    : local-nvme (default, rancher/local-path-provisioner)"
echo "  Backup target   : S3"
echo "========================================================"
