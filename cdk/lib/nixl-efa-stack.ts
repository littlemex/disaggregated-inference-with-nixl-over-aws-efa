import {
  Stack,
  StackProps,
  CfnOutput,
  Tags,
  Fn,
  RemovalPolicy,
  Annotations,
} from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as s3 from "aws-cdk-lib/aws-s3";
import { Construct } from "constructs";

/**
 * EFA-supported instance types
 * Reference: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html
 */
const EFA_SUPPORTED_INSTANCE_TYPES = [
  // G5 series (NVIDIA A10G)
  "g5.12xlarge",
  "g5.24xlarge",
  "g5.48xlarge",
  // G6 series (NVIDIA L4)
  "g6.12xlarge",
  "g6.24xlarge",
  "g6.48xlarge",
  // G6e series (NVIDIA L40S)
  "g6e.12xlarge",
  "g6e.24xlarge",
  "g6e.48xlarge",
  // G7e series (NVIDIA RTX PRO 6000 Blackwell Server Edition)
  // Note: EFA supported on g7e.8xlarge and larger only
  "g7e.8xlarge",
  "g7e.12xlarge",
  "g7e.24xlarge",
  "g7e.48xlarge",
  // P4d series (NVIDIA A100)
  "p4d.24xlarge",
  // P4de series (NVIDIA A100)
  "p4de.24xlarge",
  // P5 series (NVIDIA H100)
  "p5.48xlarge",
  // Trn1 series (AWS Trainium)
  "trn1.32xlarge",
  "trn1n.32xlarge",
  // Inf2 series (AWS Inferentia2)
  "inf2.24xlarge",
  "inf2.48xlarge",
];

/**
 * Recommended volume sizes by instance type (in GB)
 */
const RECOMMENDED_VOLUME_SIZES: Record<string, number> = {
  "g5.12xlarge": 200,
  "g5.24xlarge": 300,
  "g5.48xlarge": 500,
  "g6.12xlarge": 200,
  "g6.24xlarge": 300,
  "g6.48xlarge": 500,
  "g6e.12xlarge": 200,
  "g6e.24xlarge": 300,
  "g6e.48xlarge": 500,
  "g7e.2xlarge": 200,
  "g7e.4xlarge": 200,
  "g7e.8xlarge": 300,
  "g7e.12xlarge": 300,
  "g7e.24xlarge": 500,
  "g7e.48xlarge": 1000,
  "p4d.24xlarge": 500,
  "p4de.24xlarge": 500,
  "p5.48xlarge": 1000,
  "trn1.32xlarge": 500,
  "trn1n.32xlarge": 500,
  "inf2.24xlarge": 300,
  "inf2.48xlarge": 500,
};

export interface NixlEfaStackProps extends StackProps {
  /** EC2 instance type. Defaults to g5.12xlarge. Must support EFA. */
  instanceType?: string;

  /** SSH key pair name (optional). Only required if you need direct SSH access. SSM Session Manager is recommended. */
  keyName?: string;

  /** Root volume size in GB. Defaults to 200. */
  volumeSize?: number;

  /** vLLM HTTP port. Defaults to 8100. */
  vllmPort?: number;

  /** Availability zone. If not specified, uses the first AZ in the region. */
  availabilityZone?: string;

  /** VPC ID. If not specified, uses the default VPC. */
  vpcId?: string;

  /** MLflow Tracking Server ARN (optional). */
  mlflowTrackingServerArn?: string;

  /** Use ML Capacity Block for purchasing capacity (optional). */
  useCapacityBlock?: boolean;

  /** Capacity Reservation ID for targeting a specific reservation (optional). */
  capacityReservationId?: string;
}

export class NixlEfaStack extends Stack {
  public readonly node1: ec2.CfnInstance;
  public readonly node2: ec2.CfnInstance;
  public readonly securityGroup: ec2.ISecurityGroup;
  public readonly placementGroup: ec2.CfnPlacementGroup;
  public readonly vpc: ec2.IVpc;
  public readonly scriptsBucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: NixlEfaStackProps) {
    super(scope, id, props);

    const {
      instanceType = "g5.12xlarge",
      keyName,
      volumeSize,
      vllmPort = 8100,
      availabilityZone,
      vpcId,
      mlflowTrackingServerArn,
      useCapacityBlock,
      capacityReservationId,
    } = props;

    // --- Validate instance type ---
    if (!EFA_SUPPORTED_INSTANCE_TYPES.includes(instanceType)) {
      Annotations.of(this).addWarning(
        `Instance type ${instanceType} may not support EFA. ` +
        `Supported types: ${EFA_SUPPORTED_INSTANCE_TYPES.join(", ")}`
      );
    }

    // --- Determine volume size ---
    const recommendedVolumeSize = RECOMMENDED_VOLUME_SIZES[instanceType] || 200;
    const finalVolumeSize = volumeSize || recommendedVolumeSize;

    // Warn if volume size is significantly smaller than recommended
    if (volumeSize && volumeSize < recommendedVolumeSize * 0.8) {
      Annotations.of(this).addWarning(
        `Volume size ${volumeSize}GB is smaller than recommended ${recommendedVolumeSize}GB for ${instanceType}`
      );
    }

    // --- VPC ---
    this.vpc = vpcId
      ? ec2.Vpc.fromLookup(this, "Vpc", { vpcId })
      : ec2.Vpc.fromLookup(this, "DefaultVpc", { isDefault: true });

    // --- Availability Zone ---
    const az = availabilityZone || this.vpc.availabilityZones[0];

    // --- AMI: Deep Learning OSS Nvidia Driver AMI ---
    const ami = ec2.MachineImage.lookup({
      name: "Deep Learning OSS Nvidia Driver AMI GPU PyTorch * (Ubuntu 22.04) *",
      owners: ["amazon"],
    });

    // --- Security Group ---
    this.securityGroup = new ec2.SecurityGroup(this, "NixlEfaSecurityGroup", {
      vpc: this.vpc,
      description: "Security group for NIXL EFA experiments",
      allowAllOutbound: true,
    });

    // Note: SSH port (22) is NOT opened. Use SSM Session Manager for secure access.

    // vLLM HTTP access (VPC only)
    this.securityGroup.addIngressRule(
      ec2.Peer.ipv4(this.vpc.vpcCidrBlock),
      ec2.Port.tcp(vllmPort),
      "Allow vLLM HTTP from VPC"
    );

    // All traffic within security group (for EFA)
    // EFA requires all protocols, not just TCP
    this.securityGroup.addIngressRule(
      this.securityGroup,
      ec2.Port.allTraffic(),
      "All traffic within security group for EFA"
    );

    // --- Placement Group ---
    this.placementGroup = new ec2.CfnPlacementGroup(this, "NixlClusterPlacementGroup", {
      strategy: "cluster",
    });

    // --- S3 Bucket for Scripts ---
    this.scriptsBucket = new s3.Bucket(this, "ScriptsBucket", {
      removalPolicy: RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      versioned: false,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
    });

    // --- IAM Role for EC2 with SSM ---
    const ec2Role = new iam.Role(this, "NixlEfaInstanceRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      description: "IAM role for NIXL EFA EC2 instances with SSM, S3, and SageMaker MLflow access",
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore"),
      ],
    });

    // Grant S3 read access to scripts bucket
    this.scriptsBucket.grantRead(ec2Role);

    // CloudWatch Logs access for SSM session logging
    ec2Role.addToPolicy(
      new iam.PolicyStatement({
        actions: [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ],
        resources: [
          `arn:aws:logs:${this.region}:${this.account}:log-group:/aws/ssm/*`,
        ],
      })
    );

    // Allow access to MLflow if provided
    if (mlflowTrackingServerArn) {
      // Control Plane: MLflow Tracking Server management operations
      ec2Role.addToPolicy(
        new iam.PolicyStatement({
          sid: "SageMakerMLflowControlPlane",
          actions: [
            "sagemaker:DescribeMlflowTrackingServer",
            "sagemaker:CreatePresignedMlflowTrackingServerUrl",
          ],
          resources: [mlflowTrackingServerArn],
        })
      );

      // Data Plane: MLflow REST API calls (experiments, runs, metrics, etc.)
      ec2Role.addToPolicy(
        new iam.PolicyStatement({
          sid: "SageMakerMLflowDataPlane",
          actions: ["sagemaker-mlflow:*"],
          resources: [mlflowTrackingServerArn],
        })
      );
    }

    const instanceProfile = new iam.CfnInstanceProfile(this, "NixlEfaInstanceProfile", {
      roles: [ec2Role.roleName],
    });

    // --- User Data ---
    const userData = ec2.UserData.forLinux();
    if (mlflowTrackingServerArn) {
      userData.addCommands(
        "#!/bin/bash",
        "# Set MLflow Tracking Server ARN (scripts will generate presigned URL at runtime)",
        `echo 'export MLFLOW_TRACKING_ARN="${mlflowTrackingServerArn}"' >> /etc/environment`,
        "# Set AWS default region for CLI commands",
        `echo 'export AWS_DEFAULT_REGION="${this.region}"' >> /etc/environment`,
        "# Install dependencies",
        "apt-get update -qq",
        "apt-get install -y -qq jq",
      );
    } else {
      userData.addCommands(
        "#!/bin/bash",
        "# Set AWS default region for CLI commands",
        `echo 'export AWS_DEFAULT_REGION="${this.region}"' >> /etc/environment`,
        "# Install dependencies",
        "apt-get update -qq",
        "apt-get install -y -qq jq",
      );
    }

    // --- Subnet ---
    // Select subnet in the specified AZ
    // If no AZ is specified, CDK will select the first available subnet
    const subnetSelection = availabilityZone
      ? {
          availabilityZones: [az],
          onePerAz: true,
        }
      : {
          onePerAz: true,
        };

    const subnet = this.vpc.selectSubnets(subnetSelection).subnets[0];

    // --- EFA Network Interface: Node 1 ---
    const node1Efa = new ec2.CfnNetworkInterface(this, "Node1EfaInterface", {
      subnetId: subnet.subnetId,
      groupSet: [this.securityGroup.securityGroupId],
      interfaceType: "efa",
      tags: [{ key: "Name", value: "node1-efa" }],
    });

    // --- EFA Network Interface: Node 2 ---
    const node2Efa = new ec2.CfnNetworkInterface(this, "Node2EfaInterface", {
      subnetId: subnet.subnetId,
      groupSet: [this.securityGroup.securityGroupId],
      interfaceType: "efa",
      tags: [{ key: "Name", value: "node2-efa" }],
    });

    // --- EC2 Instance: Node 1 ---
    const node1Props: ec2.CfnInstanceProps = {
      imageId: ami.getImage(this).imageId,
      instanceType,
      keyName,
      placementGroupName: this.placementGroup.ref,
      availabilityZone: az,
      iamInstanceProfile: instanceProfile.ref,
      networkInterfaces: [
        {
          networkInterfaceId: node1Efa.ref,
          deviceIndex: "0",
        },
      ],
      blockDeviceMappings: [
        {
          deviceName: "/dev/sda1",
          ebs: {
            volumeSize: finalVolumeSize,
            volumeType: "gp3",
          },
        },
      ],
      userData: Fn.base64(userData.render()),
      tags: [
        { key: "Name", value: "nixl-node1" },
        { key: "Role", value: "producer" },
      ],
    };

    // Add capacity block configuration if enabled
    if (useCapacityBlock) {
      (node1Props as any).instanceMarketOptions = {
        marketType: "capacity-block",
      };
    }

    // Add capacity reservation specification if provided
    if (capacityReservationId) {
      (node1Props as any).capacityReservationSpecification = {
        capacityReservationTarget: {
          capacityReservationId: capacityReservationId,
        },
      };
    }

    this.node1 = new ec2.CfnInstance(this, "Node1", node1Props);

    this.node1.addDependency(this.placementGroup);

    // --- EC2 Instance: Node 2 ---
    const node2Props: ec2.CfnInstanceProps = {
      imageId: ami.getImage(this).imageId,
      instanceType,
      keyName,
      placementGroupName: this.placementGroup.ref,
      availabilityZone: az,
      iamInstanceProfile: instanceProfile.ref,
      networkInterfaces: [
        {
          networkInterfaceId: node2Efa.ref,
          deviceIndex: "0",
        },
      ],
      blockDeviceMappings: [
        {
          deviceName: "/dev/sda1",
          ebs: {
            volumeSize: finalVolumeSize,
            volumeType: "gp3",
          },
        },
      ],
      userData: Fn.base64(userData.render()),
      tags: [
        { key: "Name", value: "nixl-node2" },
        { key: "Role", value: "consumer" },
      ],
    };

    // Add capacity block configuration if enabled
    if (useCapacityBlock) {
      (node2Props as any).instanceMarketOptions = {
        marketType: "capacity-block",
      };
    }

    // Add capacity reservation specification if provided
    if (capacityReservationId) {
      (node2Props as any).capacityReservationSpecification = {
        capacityReservationTarget: {
          capacityReservationId: capacityReservationId,
        },
      };
    }

    this.node2 = new ec2.CfnInstance(this, "Node2", node2Props);

    this.node2.addDependency(this.placementGroup);

    // --- Outputs ---
    new CfnOutput(this, "Node1InstanceId", {
      value: this.node1.ref,
      description: "Node 1 instance ID",
      exportName: `${this.stackName}-Node1InstanceId`,
    });

    new CfnOutput(this, "Node1PublicIp", {
      value: this.node1.attrPublicIp,
      description: "Node 1 public IP address",
      exportName: `${this.stackName}-Node1PublicIp`,
    });

    new CfnOutput(this, "Node1PrivateIp", {
      value: this.node1.attrPrivateIp,
      description: "Node 1 private IP address",
      exportName: `${this.stackName}-Node1PrivateIp`,
    });

    new CfnOutput(this, "Node2InstanceId", {
      value: this.node2.ref,
      description: "Node 2 instance ID",
      exportName: `${this.stackName}-Node2InstanceId`,
    });

    new CfnOutput(this, "Node2PublicIp", {
      value: this.node2.attrPublicIp,
      description: "Node 2 public IP address",
      exportName: `${this.stackName}-Node2PublicIp`,
    });

    new CfnOutput(this, "Node2PrivateIp", {
      value: this.node2.attrPrivateIp,
      description: "Node 2 private IP address",
      exportName: `${this.stackName}-Node2PrivateIp`,
    });

    new CfnOutput(this, "ScriptsBucketName", {
      value: this.scriptsBucket.bucketName,
      description: "S3 bucket for deployment scripts",
      exportName: `${this.stackName}-ScriptsBucketName`,
    });

    new CfnOutput(this, "SecurityGroupId", {
      value: this.securityGroup.securityGroupId,
      description: "Security group ID",
      exportName: `${this.stackName}-SecurityGroupId`,
    });

    new CfnOutput(this, "PlacementGroupName", {
      value: this.placementGroup.ref,
      description: "Placement group name",
      exportName: `${this.stackName}-PlacementGroupName`,
    });
  }
}
