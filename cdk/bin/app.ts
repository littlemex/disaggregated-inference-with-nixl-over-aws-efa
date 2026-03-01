#!/usr/bin/env node
import "source-map-support/register";
import { App, Tags } from "aws-cdk-lib";
import { MlflowStack } from "../lib/mlflow-stack";
import { NixlEfaStack } from "../lib/nixl-efa-stack";

const app = new App();

// ========================================
// Stack Naming Strategy
// ========================================

/**
 * Get stack name based on environment and deployment context
 *
 * Naming patterns:
 * - With prefix: {prefix}-{namespace}-{environment}-{region-short}
 * - Standard: {namespace}-{environment}-{region-short}
 * - Feature branch: {namespace}-{branch}-{short-hash}
 * - Manual override: use -c stackName=CustomName
 */
function getStackName(
  app: App,
  namespace: string,
  defaultEnvironment: string = "dev"
): string {
  // 1. Manual override (highest priority)
  const manualStackName = app.node.tryGetContext(`${namespace}StackName`);
  if (manualStackName) {
    return manualStackName;
  }

  // 2. Project prefix support (for avoiding stack name collisions)
  const projectPrefix = app.node.tryGetContext("projectPrefix");

  // 3. Environment-based naming (standard)
  const environment = app.node.tryGetContext("environment") || defaultEnvironment;
  const region = process.env.CDK_DEFAULT_REGION || "us-west-2";

  // Shorten region name for brevity (us-west-2 -> west-2)
  const regionShort = region.replace(/^(us|eu|ap|ca|sa|me|af)-/, "");

  // 4. Feature branch support (optional)
  const branch = app.node.tryGetContext("branch");
  if (branch && branch !== "main" && branch !== "master") {
    // Sanitize branch name (remove special characters)
    const sanitizedBranch = branch
      .replace(/[^a-zA-Z0-9-]/g, "-")
      .substring(0, 20);

    // Optional: Add short git hash for uniqueness
    const gitHash = app.node.tryGetContext("gitHash");
    const hashSuffix = gitHash ? `-${gitHash.substring(0, 7)}` : "";

    const baseName = `${namespace}-${sanitizedBranch}${hashSuffix}`;
    return projectPrefix ? `${projectPrefix}-${baseName}` : baseName;
  }

  // 5. Standard naming: [prefix-]namespace-environment-region
  const baseName = `${namespace}-${environment}-${regionShort}`;
  return projectPrefix ? `${projectPrefix}-${baseName}` : baseName;
}

/**
 * Get common stack tags based on context
 */
function getStackTags(app: App): Record<string, string> {
  const environment = app.node.tryGetContext("environment") || "dev";
  const branch = app.node.tryGetContext("branch");
  const owner = app.node.tryGetContext("owner") || "nixl-team";

  return {
    Environment: environment,
    Project: "NIXL-EFA",
    Owner: owner,
    ManagedBy: "CDK",
    ...(branch && { Branch: branch }),
  };
}

// ========================================
// MLflow Stack
// ========================================

const projectPrefix = app.node.tryGetContext("projectPrefix");
const vpcId = app.node.tryGetContext("vpcId");
const createVpc = app.node.tryGetContext("createVpc") === "true";
const trackingServerSize = app.node.tryGetContext("trackingServerSize");
const bucketName = app.node.tryGetContext("bucketName");
const trackingServerNameBase = app.node.tryGetContext("trackingServerName") || "mlflow-tracking-server";
const trackingServerName = projectPrefix
  ? `${projectPrefix}-${trackingServerNameBase}`
  : trackingServerNameBase;
const allowedCidrsRaw = app.node.tryGetContext("allowedCidrs");
const allowedCidrs = allowedCidrsRaw
  ? (allowedCidrsRaw as string).split(",")
  : [];

// Generate unique stack name for MLflow
const mlflowStackName = getStackName(app, "mlflow", "prod");

const mlflowStack = new MlflowStack(app, mlflowStackName, {
  stackName: mlflowStackName, // Explicit stack name to avoid conflicts
  vpcId: vpcId || undefined,
  createVpc,
  trackingServerSize: trackingServerSize as "Small" | "Medium" | "Large" | undefined,
  bucketName: bucketName || undefined,
  allowedCidrs,
  trackingServerName,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || "us-east-1",
  },
});

// Apply common tags to MLflow stack
const commonTags = getStackTags(app);
Object.entries(commonTags).forEach(([key, value]) => {
  Tags.of(mlflowStack).add(key, value);
});

// ========================================
// NIXL EFA Stack
// ========================================

const keyName = app.node.tryGetContext("keyName"); // Optional: only if you need SSH access
const instanceType = app.node.tryGetContext("instanceType") || "g5.12xlarge";
const volumeSize = app.node.tryGetContext("volumeSize")
  ? parseInt(app.node.tryGetContext("volumeSize"))
  : undefined;
const vllmPort = app.node.tryGetContext("vllmPort")
  ? parseInt(app.node.tryGetContext("vllmPort"))
  : 8100;
const availabilityZone = app.node.tryGetContext("availabilityZone");
const useCapacityBlock = app.node.tryGetContext("useCapacityBlock") === "true";
const capacityReservationId = app.node.tryGetContext("capacityReservationId");

// Get MLflow ARN and artifact bucket ARN from MLflow stack output
const mlflowArn = mlflowStack.trackingServer.attrTrackingServerArn;
const mlflowArtifactBucketArn = mlflowStack.artifactBucket.bucketArn;

// Generate unique stack name for NIXL EFA
const nixlEfaStackName = getStackName(app, "nixl-efa", "dev");

const nixlEfaStack = new NixlEfaStack(app, nixlEfaStackName, {
  stackName: nixlEfaStackName, // Explicit stack name to avoid conflicts
  keyName: keyName || undefined,
  instanceType,
  volumeSize,
  vllmPort,
  availabilityZone,
  vpcId: vpcId || undefined,
  mlflowTrackingServerArn: mlflowArn,
  mlflowArtifactBucketArn,
  useCapacityBlock,
  capacityReservationId: capacityReservationId || undefined,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || "us-east-1",
  },
});

// Explicitly define stack dependency to ensure MLflow is deployed first
nixlEfaStack.addDependency(mlflowStack);

// Apply common tags to NIXL EFA stack
Object.entries(commonTags).forEach(([key, value]) => {
  Tags.of(nixlEfaStack).add(key, value);
});

app.synth();
