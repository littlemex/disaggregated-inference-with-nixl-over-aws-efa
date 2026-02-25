import {
  Stack,
  StackProps,
  CfnOutput,
  RemovalPolicy,
  Tags,
} from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as sagemaker from "aws-cdk-lib/aws-sagemaker";
import { Construct } from "constructs";

export type TrackingServerSize = "Small" | "Medium" | "Large";

export interface MlflowStackProps extends StackProps {
  /** Existing VPC ID to use. If not provided and createVpc is true, a new VPC is created. */
  vpcId?: string;

  /** Whether to create a new VPC. Defaults to false. */
  createVpc?: boolean;

  /** Tracking Server size: Small, Medium, or Large. If undefined, "Small" is used as default. */
  trackingServerSize?: TrackingServerSize;

  /** S3 bucket name for artifacts. Auto-generated if not provided. */
  bucketName?: string;

  /** CIDR ranges allowed to access the tracking server. */
  allowedCidrs?: string[];

  /** Tracking server name. Defaults to 'mlflow-tracking-server'. */
  trackingServerName?: string;
}

export class MlflowStack extends Stack {
  public readonly artifactBucket: s3.IBucket;
  public readonly trackingServerRole: iam.IRole;
  public readonly vpc: ec2.IVpc;
  public readonly securityGroup: ec2.ISecurityGroup;
  public readonly trackingServer: sagemaker.CfnMlflowTrackingServer;

  constructor(scope: Construct, id: string, props: MlflowStackProps = {}) {
    super(scope, id, props);

    const {
      vpcId,
      createVpc = false,
      trackingServerSize,
      bucketName,
      allowedCidrs = [],
      trackingServerName = "mlflow-tracking-server",
    } = props;

    // --- VPC ---
    this.vpc = this.resolveVpc(vpcId, createVpc);

    // --- Security Group ---
    this.securityGroup = new ec2.SecurityGroup(this, "MlflowSecurityGroup", {
      vpc: this.vpc,
      description: "Security group for MLflow Tracking Server access",
      allowAllOutbound: true,
    });

    // Allow HTTPS (443) from VPC CIDR
    this.securityGroup.addIngressRule(
      ec2.Peer.ipv4(this.vpc.vpcCidrBlock),
      ec2.Port.tcp(443),
      "Allow HTTPS from VPC"
    );

    // Allow additional CIDRs
    for (const cidr of allowedCidrs) {
      this.securityGroup.addIngressRule(
        ec2.Peer.ipv4(cidr),
        ec2.Port.tcp(443),
        `Allow HTTPS from ${cidr}`
      );
    }

    // --- S3 Bucket ---
    this.artifactBucket = new s3.Bucket(this, "MlflowArtifactBucket", {
      bucketName,
      removalPolicy: RemovalPolicy.RETAIN,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      versioned: true,
      enforceSSL: true,
    });

    // --- IAM Role for SageMaker MLflow ---
    this.trackingServerRole = new iam.Role(this, "MlflowTrackingServerRole", {
      assumedBy: new iam.ServicePrincipal("sagemaker.amazonaws.com"),
      description: "IAM role for SageMaker MLflow Tracking Server",
    });

    this.trackingServerRole.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSageMakerFullAccess")
    );

    this.artifactBucket.grantReadWrite(this.trackingServerRole);

    // --- IAM Role for EC2 nodes accessing MLflow ---
    const ec2AccessRole = new iam.Role(this, "MlflowEc2AccessRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      description: "IAM role for EC2 nodes to access MLflow Tracking Server",
    });

    ec2AccessRole.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSageMakerFullAccess")
    );

    this.artifactBucket.grantReadWrite(ec2AccessRole);

    const ec2InstanceProfile = new iam.CfnInstanceProfile(
      this,
      "MlflowEc2InstanceProfile",
      {
        roles: [ec2AccessRole.roleName],
        instanceProfileName: `${trackingServerName}-ec2-profile`,
      }
    );

    // --- SageMaker MLflow Tracking Server ---
    // trackingServerSize を省略すると Small がデフォルト値として使用される
    // 有効な値: Small, Medium, Large（Serverless モードは存在しない）
    const trackingServerProps: sagemaker.CfnMlflowTrackingServerProps = {
      trackingServerName,
      artifactStoreUri: `s3://${this.artifactBucket.bucketName}/mlflow-artifacts`,
      roleArn: this.trackingServerRole.roleArn,
      trackingServerSize: trackingServerSize || "Small", // 明示的にデフォルト値を指定
    };

    this.trackingServer = new sagemaker.CfnMlflowTrackingServer(
      this,
      "MlflowTrackingServer",
      trackingServerProps
    );

    this.trackingServer.node.addDependency(this.artifactBucket);

    // --- Tags ---
    Tags.of(this).add("Project", "mlflow-tracking");
    Tags.of(this).add("ManagedBy", "cdk");

    // --- Outputs ---
    new CfnOutput(this, "TrackingServerName", {
      value: trackingServerName,
      description: "MLflow Tracking Server name",
    });

    new CfnOutput(this, "TrackingServerArn", {
      value: this.trackingServer.attrTrackingServerArn,
      description: "MLflow Tracking Server ARN",
    });

    new CfnOutput(this, "ArtifactBucketName", {
      value: this.artifactBucket.bucketName,
      description: "S3 bucket for MLflow artifacts",
    });

    new CfnOutput(this, "ArtifactBucketArn", {
      value: this.artifactBucket.bucketArn,
      description: "S3 bucket ARN for MLflow artifacts",
    });

    new CfnOutput(this, "TrackingServerRoleArn", {
      value: this.trackingServerRole.roleArn,
      description: "IAM role ARN for Tracking Server",
    });

    new CfnOutput(this, "Ec2AccessRoleArn", {
      value: ec2AccessRole.roleArn,
      description: "IAM role ARN for EC2 nodes to access MLflow",
    });

    new CfnOutput(this, "Ec2InstanceProfileArn", {
      value: ec2InstanceProfile.attrArn,
      description: "Instance profile ARN for EC2 nodes",
    });

    new CfnOutput(this, "SecurityGroupId", {
      value: this.securityGroup.securityGroupId,
      description: "Security group ID for MLflow access",
    });

    new CfnOutput(this, "VpcId", {
      value: this.vpc.vpcId,
      description: "VPC ID used by the MLflow stack",
    });
  }

  private resolveVpc(vpcId?: string, createVpc?: boolean): ec2.IVpc {
    if (vpcId) {
      return ec2.Vpc.fromLookup(this, "ExistingVpc", { vpcId });
    }

    if (createVpc) {
      return new ec2.Vpc(this, "MlflowVpc", {
        maxAzs: 2,
        natGateways: 1,
        subnetConfiguration: [
          {
            cidrMask: 24,
            name: "Public",
            subnetType: ec2.SubnetType.PUBLIC,
          },
          {
            cidrMask: 24,
            name: "Private",
            subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
          },
        ],
      });
    }

    // Default: look up the default VPC
    return ec2.Vpc.fromLookup(this, "DefaultVpc", { isDefault: true });
  }
}
