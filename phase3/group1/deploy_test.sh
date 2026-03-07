#!/bin/bash
set -e

# Deploy EFA RDMA Read test program to nodes

NODE1_IP=${NODE1_IP:-172.31.2.221}
NODE2_IP=${NODE2_IP:-172.31.10.117}

echo "[INFO] Uploading test files to S3..."
aws s3 cp test_efa_rdma.cpp s3://phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj/test/ --region us-west-2
aws s3 cp Makefile s3://phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj/test/ --region us-west-2

echo "[INFO] Deploying to Node1 (Producer)..."
aws ssm send-command \
  --instance-ids i-050ac7e7a9986ccc7 \
  --region us-west-2 \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=[
    "mkdir -p /home/ubuntu/efa_test",
    "cd /home/ubuntu/efa_test",
    "aws s3 cp s3://phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj/test/test_efa_rdma.cpp . --region us-west-2",
    "aws s3 cp s3://phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj/test/Makefile . --region us-west-2",
    "make clean || true",
    "make",
    "echo DEPLOY_COMPLETE"
  ]' \
  --output text --query 'Command.CommandId'

echo "[INFO] Deploying to Node2 (Consumer)..."
aws ssm send-command \
  --instance-ids i-0634bbcbb9d65d4e3 \
  --region us-west-2 \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=[
    "mkdir -p /home/ubuntu/efa_test",
    "cd /home/ubuntu/efa_test",
    "aws s3 cp s3://phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj/test/test_efa_rdma.cpp . --region us-west-2",
    "aws s3 cp s3://phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj/test/Makefile . --region us-west-2",
    "make clean || true",
    "make",
    "echo DEPLOY_COMPLETE"
  ]' \
  --output text --query 'Command.CommandId'

echo "[OK] Deployment initiated. Wait for completion before running tests."
