import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as batch from 'aws-cdk-lib/aws-batch';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as ecr_assets from 'aws-cdk-lib/aws-ecr-assets';
import { Construct } from 'constructs';
import * as path from 'path';
import * as fs from 'fs';

export interface AgenticBatchStackProps extends cdk.StackProps {
  /** Prefix for resource names. */
  projectName?: string;
  /**
   * Bedrock inference profile ID for the agent's primary model. Pin a specific
   * version rather than an alias: aliases resolve to the CLI's built-in default,
   * which changes between releases. Changing this value needs no image rebuild.
   */
  modelId?: string;
  /** Bedrock inference profile ID for the agent's lightweight helper model. */
  haikuModelId?: string;
}

export class AgenticBatchStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: AgenticBatchStackProps) {
    super(scope, id, props);

    const projectName = props?.projectName || 'agentic-batch';
    const modelId = props?.modelId || 'us.anthropic.claude-sonnet-4-6';
    const haikuModelId =
      props?.haikuModelId || 'us.anthropic.claude-haiku-4-5-20251001-v1:0';

    // ============================================================
    // NETWORKING
    // ============================================================
    // Only isolated subnets are declared. There is no public subnet tier, so
    // CDK creates no internet gateway, and natGateways: 0 means no NAT gateway
    // either. The result is a VPC with no route to the public internet at all;
    // every AWS API call leaves through one of the VPC endpoints below.
    const vpc = new ec2.Vpc(this, 'VPC', {
      vpcName: `${projectName}-vpc`,
      maxAzs: 2,
      natGateways: 0,
      subnetConfiguration: [
        {
          cidrMask: 24,
          name: 'Isolated',
          subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
        },
      ],
    });

    const endpointSecurityGroup = new ec2.SecurityGroup(this, 'EndpointSecurityGroup', {
      vpc,
      description: 'Security group for VPC endpoints',
      allowAllOutbound: true,
    });

    endpointSecurityGroup.addIngressRule(
      ec2.Peer.ipv4(vpc.vpcCidrBlock),
      ec2.Port.tcp(443),
      'Allow HTTPS from within the VPC'
    );

    // ============================================================
    // VPC ENDPOINTS - the only egress path
    // ============================================================
    vpc.addGatewayEndpoint('S3Endpoint', {
      service: ec2.GatewayVpcEndpointAwsService.S3,
      subnets: [{ subnetType: ec2.SubnetType.PRIVATE_ISOLATED }],
    });

    vpc.addGatewayEndpoint('DynamoDBEndpoint', {
      service: ec2.GatewayVpcEndpointAwsService.DYNAMODB,
      subnets: [{ subnetType: ec2.SubnetType.PRIVATE_ISOLATED }],
    });

    // ECR needs both endpoints: ECR API for authentication and metadata, ECR
    // DKR for the image layers themselves. One without the other fails the pull.
    vpc.addInterfaceEndpoint('ECRAPIEndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.ECR,
      privateDnsEnabled: true,
      securityGroups: [endpointSecurityGroup],
      subnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
    });

    vpc.addInterfaceEndpoint('ECRDKREndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.ECR_DOCKER,
      privateDnsEnabled: true,
      securityGroups: [endpointSecurityGroup],
      subnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
    });

    vpc.addInterfaceEndpoint('CloudWatchLogsEndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.CLOUDWATCH_LOGS,
      privateDnsEnabled: true,
      securityGroups: [endpointSecurityGroup],
      subnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
    });

    vpc.addInterfaceEndpoint('BedrockRuntimeEndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.BEDROCK_RUNTIME,
      privateDnsEnabled: true,
      securityGroups: [endpointSecurityGroup],
      subnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
    });

    // ============================================================
    // S3 - input and output prefixes
    // ============================================================
    // This is sample code: the bucket and its contents are removed by
    // `cdk destroy` so the walkthrough leaves nothing behind. For anything you
    // care about, change these to RemovalPolicy.RETAIN.
    // For production, also enable S3 server access logging by passing a
    // serverAccessLogsBucket here (omitted in this sample to avoid provisioning
    // a second bucket).
    const dataBucket = new s3.Bucket(this, 'DataBucket', {
      bucketName: `${projectName}-${this.account}`,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // ============================================================
    // DYNAMODB - the per-item ledger
    // ============================================================
    // The partition key is the item ID alone, which makes the worker's
    // idempotency check a single GetItem. If you will ever process the same item
    // twice (to compare two model configurations, say), add a sort key for the
    // run ID or namespace the item IDs per run. With item_id alone, a comparison
    // run is silently skipped as already-processed.
    const runLedger = new dynamodb.Table(this, 'RunLedger', {
      tableName: `${projectName}-ledger`,
      partitionKey: { name: 'item_id', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ============================================================
    // CONTAINER IMAGE - built locally, pushed to ECR by the CDK
    // ============================================================
    // Because this builds the image, `cdk deploy` has to run somewhere with a
    // Docker daemon available. See the README prerequisites.
    const workerImage = new ecr_assets.DockerImageAsset(this, 'WorkerImage', {
      directory: path.join(__dirname, '..', 'container'),
      platform: ecr_assets.Platform.LINUX_AMD64,
    });

    // ============================================================
    // CLOUDWATCH LOGS
    // ============================================================
    const logGroup = new logs.LogGroup(this, 'BatchLogGroup', {
      logGroupName: `/aws/batch/${projectName}`,
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ============================================================
    // IAM
    // ============================================================
    const taskRole = new iam.Role(this, 'BatchTaskRole', {
      roleName: `${projectName}-task-role`,
      assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
      description: 'Role assumed by the worker container',
    });

    // Scope S3 access to the two prefixes the worker actually uses.
    dataBucket.grantRead(taskRole, 'input/*');
    dataBucket.grantWrite(taskRole, 'output/*');

    runLedger.grantReadWriteData(taskRole);
    logGroup.grantWrite(taskRole);

    // Note the wildcard Region. Cross-Region inference profiles can route a
    // request to a Region other than the one called, so a Region-pinned ARN
    // produces intermittent access-denied errors that are unpleasant to
    // diagnose because most requests still succeed.
    //
    // The two read actions let the CLI resolve an inference profile to its
    // backing foundation model. Without them it falls back to an alternate
    // request shape that works but adds a round-trip per model.
    taskRole.addToPolicy(new iam.PolicyStatement({
      sid: 'BedrockInvoke',
      effect: iam.Effect.ALLOW,
      actions: [
        'bedrock:InvokeModel',
        'bedrock:InvokeModelWithResponseStream',
        'bedrock:ListInferenceProfiles',
        'bedrock:GetInferenceProfile',
      ],
      resources: [
        'arn:aws:bedrock:*:*:inference-profile/*',
        'arn:aws:bedrock:*:*:application-inference-profile/*',
        'arn:aws:bedrock:*::foundation-model/*',
      ],
    }));

    const executionRole = new iam.Role(this, 'BatchExecutionRole', {
      roleName: `${projectName}-execution-role`,
      assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName(
          'service-role/AmazonECSTaskExecutionRolePolicy'
        ),
      ],
    });

    workerImage.repository.grantPull(executionRole);

    // ============================================================
    // AWS BATCH ON FARGATE
    // ============================================================
    // maxvCpus is the concurrency ceiling. Many concurrent containers share the
    // account's Bedrock throughput, so check your tokens-per-minute quota
    // against this number before the first large batch.
    const computeEnvironment = new batch.FargateComputeEnvironment(this, 'ComputeEnvironment', {
      computeEnvironmentName: `${projectName}-compute-env`,
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
      maxvCpus: 16,
    });

    const jobQueue = new batch.JobQueue(this, 'JobQueue', {
      jobQueueName: `${projectName}-queue`,
      priority: 1,
      computeEnvironments: [{ computeEnvironment, order: 1 }],
    });

    const jobDefinition = new batch.EcsJobDefinition(this, 'JobDefinition', {
      jobDefinitionName: `${projectName}-worker`,
      container: new batch.EcsFargateContainerDefinition(this, 'ContainerDefinition', {
        image: ecs.ContainerImage.fromDockerImageAsset(workerImage),
        // Size the task for the agent, not for the wrapper. An agentic run holds
        // conversation state and tool output in memory; an under-provisioned
        // task does not fail, it runs several times slower.
        cpu: 2,
        memory: cdk.Size.mebibytes(8192),
        jobRole: taskRole,
        executionRole: executionRole,
        assignPublicIp: false,
        logging: ecs.LogDrivers.awsLogs({
          streamPrefix: projectName,
          logGroup: logGroup,
        }),
        environment: {
          AWS_REGION: this.region,
          S3_BUCKET: dataBucket.bucketName,
          DYNAMODB_TABLE: runLedger.tableName,
          // Routes the CLI to Bedrock instead of a public API endpoint.
          // Credentials come from the task role through the default AWS SDK
          // credential chain; there is no API key anywhere in this stack.
          CLAUDE_CODE_USE_BEDROCK: '1',
          // The model is a job-definition setting, not an image setting: change
          // it and register a new revision, no rebuild required.
          ANTHROPIC_MODEL: modelId,
          ANTHROPIC_DEFAULT_HAIKU_MODEL: haikuModelId,
        },
      }),
    });

    // ============================================================
    // CLOUDWATCH DASHBOARD
    // ============================================================
    // The dashboard body is stored as JSON rather than assembled from CDK
    // constructs because most of its widgets are Logs Insights queries over the
    // worker's structured log lines. Placeholders are substituted at synth time
    // so the stored definition carries no account-specific values.
    const dashboardBody = fs
      .readFileSync(path.join(__dirname, 'dashboard-body.json'), 'utf8')
      .replace(/__BUCKET_NAME__/g, dataBucket.bucketName)
      .replace(/__TABLE_NAME__/g, runLedger.tableName)
      .replace(/__LOG_GROUP__/g, logGroup.logGroupName)
      .replace(/__REPO_NAME__/g, workerImage.repository.repositoryName)
      .replace(/__REGION__/g, this.region);

    new cloudwatch.CfnDashboard(this, 'ObservabilityDashboard', {
      dashboardName: `${projectName}-observability`,
      dashboardBody: dashboardBody,
    });

    // ============================================================
    // OUTPUTS
    // ============================================================
    new cdk.CfnOutput(this, 'S3Bucket', {
      value: dataBucket.bucketName,
      description: 'Bucket holding the input/ and output/ prefixes',
    });

    new cdk.CfnOutput(this, 'LedgerTable', {
      value: runLedger.tableName,
      description: 'DynamoDB per-item ledger',
    });

    // Output ids must not collide with construct ids in the same scope, so
    // these two carry a Name suffix.
    new cdk.CfnOutput(this, 'JobQueueName', {
      value: jobQueue.jobQueueName,
      description: 'AWS Batch job queue',
    });

    new cdk.CfnOutput(this, 'JobDefinitionName', {
      value: jobDefinition.jobDefinitionName,
      description: 'AWS Batch job definition',
    });

    new cdk.CfnOutput(this, 'ConfiguredModel', {
      value: modelId,
      description: 'Pinned Bedrock model (change and register a new revision, no rebuild)',
    });

    new cdk.CfnOutput(this, 'DashboardURL', {
      value: `https://${this.region}.console.aws.amazon.com/cloudwatch/home?region=${this.region}#dashboards:name=${projectName}-observability`,
      description: 'Observability dashboard (populates after the first job runs)',
    });

    new cdk.CfnOutput(this, 'SubmitCommand', {
      value:
        `aws batch submit-job --job-name sample-001 ` +
        `--job-queue ${jobQueue.jobQueueName} ` +
        `--job-definition ${jobDefinition.jobDefinitionName} ` +
        `--container-overrides '{"environment":[{"name":"ITEM_ID","value":"sample-001"}]}' ` +
        `--region ${this.region}`,
      description: 'Submit one item',
    });
  }
}
