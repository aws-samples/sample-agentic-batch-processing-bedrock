# Run an existing agent CLI at scale on AWS Batch with Amazon Bedrock

Companion code for the AWS Machine Learning Blog post *Scale your existing agent
CLI with AWS Batch and Amazon Bedrock*.

This stack runs an agent CLI unchanged, one container per work item, on AWS Batch
with AWS Fargate. Amazon Bedrock provides model access through the container's IAM
task role, Amazon S3 holds input and output, and an Amazon DynamoDB table records
status, duration, token usage, and cost for every item. The VPC has no internet
gateway and no NAT gateway: every AWS API call leaves through a VPC endpoint.

The sample agent logic extracts structured fields from a plain-text document.
Replace it with your own; the wrapper does not care what the agent does.

## Architecture

| Component | Purpose |
|---|---|
| AWS Batch on AWS Fargate | One ephemeral task per work item; scales to zero |
| Amazon Bedrock | Model access, authorized by the task role, no API keys |
| Amazon S3 | `input/` and `output/` prefixes |
| Amazon DynamoDB | One ledger row per item: status, cost, tokens, duration |
| Amazon ECR | Worker image, built and pushed by the CDK |
| Amazon CloudWatch | Structured logs and an observability dashboard |
| VPC endpoints | S3 and DynamoDB gateway; Bedrock Runtime, ECR API, ECR DKR, and CloudWatch Logs interface |

## Prerequisites

- An AWS account with permissions to create Amazon VPC, Amazon S3, Amazon
  DynamoDB, Amazon ECR, AWS Batch, AWS IAM, and Amazon CloudWatch resources.
- Amazon Bedrock model access enabled in your target Region for the models you
  intend to call. Enable it before deploying: a missing grant deploys cleanly and
  then fails at run time, inside the agent, where the error is least obvious.
- Node.js 18 or later and the AWS CDK Toolkit v2.
- **Docker, running.** The CDK builds the worker image and pushes it to Amazon
  ECR, so both `cdk synth` and `cdk deploy` need a Docker daemon. Your own machine
  is the usual place to run this. If Docker is not available there, see
  [Deploying from somewhere other than your own machine](#deploying-from-somewhere-other-than-your-own-machine).

Deploy commands run on your machine; the workload runs in your account. The
container's network isolation is unrelated to how you deploy.

## First time with the AWS CDK

Skip this if you have used the CDK before.

```bash
npm install -g aws-cdk          # the CDK Toolkit, providing the `cdk` command
cdk --version                   # expect 2.x
aws sts get-caller-identity     # confirm the account and identity you will deploy into
```

The CDK uses the same credentials as the AWS CLI, so if the AWS CLI works, the CDK
works. There is nothing else to configure.

One CDK-specific step has no equivalent elsewhere:

```bash
npx cdk bootstrap
```

Bootstrapping creates the resources the CDK needs to deploy anything at all: a
staging bucket for assets, an Amazon ECR repository for images, and a few IAM
roles. Run it once per account and Region, not once per project. **`cdk destroy`
does not remove the bootstrap resources**, so after cleaning up this stack you
will still see a `cdk-*` bucket and repository. That is expected, and other CDK
projects in the account depend on them.

For anything beyond this, see the AWS documentation:
[Getting started with the AWS CDK](https://docs.aws.amazon.com/cdk/v2/guide/getting-started.html).

## Deploy

```bash
cd infrastructure
npm install
npx cdk bootstrap                 # once per account and Region
npx cdk deploy
```

Deployment usually finishes in under 10 minutes, most of it the container image
build and asset upload rather than the stack itself. The stack outputs the bucket,
table, queue, job definition, and dashboard URL.

Two warnings during `cdk synth` and `cdk deploy` look like errors and are not: a
Node version notice from the AWS SDK, and `current credentials could not be used
to assume 'arn:…:role/cdk-hnb659fds-lookup-role-…', but are for the right
account`. The second appears when you synthesize before bootstrapping that account
and Region. `npm install` also reports a high-severity advisory reached
transitively through `aws-cdk-lib`; it is not in the deployed workload's runtime
path and cannot be resolved from this repository's dependencies.

A later change to `worker.sh` or the agent logic only rebuilds the image and
updates the job definition, which takes about a minute — not a full redeploy.

## Deploying from somewhere other than your own machine

Only needed if Docker is unavailable locally, your organization restricts local
container builds, or you want a build host in the same Region as the deployment.

### Option 1: AWS CloudShell

CloudShell has Docker, Node.js, and the CDK Toolkit preinstalled, and it inherits
your console credentials, so there is nothing to configure. Clone the repository
and follow the deploy steps above.

The limits are real, though: 1 vCPU, 2 GiB of memory, and limited image storage,
which makes the image build slow and occasionally fails it. Docker availability
also varies by Region. Check the
[CloudShell supported Regions](https://docs.aws.amazon.com/cloudshell/latest/userguide/supported-aws-regions.html)
documentation first. Try CloudShell before provisioning an instance; if the build
fails there, use Option 2.

### Option 2: A short-lived Amazon EC2 instance

More setup, but no local dependencies and a faster build.

**Launch the instance.** `t3.large` (2 vCPU, 8 GiB) or larger, Amazon Linux 2023,
30 GiB of storage — the toolchain fits in 20 GiB but the image build leaves little
headroom there — in the Region you are deploying to. It needs outbound internet
access for package installs and to reach AWS APIs, so put it in a public subnet
with a public IP, or a private subnet with a NAT gateway. This is the build host,
not the workload; the workload's isolated VPC is created by the stack.

**Attach an instance profile, do not copy access keys onto it.** Create an IAM role
with the EC2 trust policy and attach a policy that permits creating the resources
this stack creates. For a temporary build host in a throwaway test account, `AdministratorAccess`
is the pragmatic choice, and deleting the instance afterwards is what bounds the
risk. If you deploy into a shared or sensitive account, do not use
`AdministratorAccess` — instead scope the role to the actions this stack needs
(Amazon EC2, Amazon S3, Amazon DynamoDB, Amazon ECR, AWS Batch, AWS IAM, Amazon
CloudWatch, and AWS CloudFormation). Then attach the role to the instance. The CDK picks the credentials up from
the instance metadata service automatically, with nothing to configure.

**Connect** with Session Manager rather than SSH, which avoids opening port 22 and
managing a key pair:

```bash
aws ssm start-session --target <instance-id>
```

This needs the SSM agent (preinstalled on Amazon Linux 2023) and the
`AmazonSSMManagedInstanceCore` managed policy on the instance role.

**Install the dependencies:**

```bash
sudo dnf install -y docker git
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"      # log out and back in for this to take effect

curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
sudo dnf install -y nodejs
npm install -g aws-cdk

docker info                          # must succeed before going further
aws sts get-caller-identity          # should show the instance role, not a user
```

Then clone the repository and follow the deploy steps above.

**Terminate the instance when the deploy finishes.** It is a build host with broad
permissions and no further purpose. The deployed stack does not depend on it, and
job submission needs only the AWS CLI, so you can submit from anywhere afterwards.
If you plan to redeploy later, stop rather than terminate: a stopped instance bills
only for its EBS volume.

## Run one item

Upload a sample document to the input prefix, then submit a job. `ITEM_ID` is the
file name without its extension.

```bash
BUCKET=$(aws cloudformation describe-stacks --stack-name AgenticBatchStack \
  --query 'Stacks[0].Outputs[?OutputKey==`S3Bucket`].OutputValue' --output text)

aws s3 cp ../samples/sample-001.txt "s3://${BUCKET}/input/sample-001.txt"

aws batch submit-job \
  --job-name sample-001 \
  --job-queue agentic-batch-queue \
  --job-definition agentic-batch-worker \
  --container-overrides '{"environment":[{"name":"ITEM_ID","value":"sample-001"}]}'
```

Then check the result and the ledger row:

```bash
aws s3 cp "s3://${BUCKET}/output/sample-001-result.json" -
aws dynamodb get-item --table-name agentic-batch-ledger \
  --key '{"item_id":{"S":"sample-001"}}'
```

**A green job status is not a successful item.** Check the ledger row, not just the
job. `cost_usd` and `num_turns` greater than zero are what tell you the model was
actually called; a row reading SUCCESS with zero cost means the container ran and
the agent did not. The worker fails the item when `num_turns` is zero for exactly
this reason, and whatever agent CLI you substitute needs its own version of that
check. Container logs are in the `/aws/batch/agentic-batch` log group, one stream
per task, with a structured line per stage.

To see idempotency work, submit the same `ITEM_ID` twice. The second job logs
`"stage":"idempotency","status":"skipped"` and exits without calling the model.

## Run many items

Submit an array job sized to the item count. Without an explicit `ITEM_ID` the
worker derives one from `AWS_BATCH_JOB_ARRAY_INDEX`, so name your inputs to match
(`item-000.txt`, `item-001.txt`, and so on), or override `ARRAY_ITEM_PREFIX`.

```bash
aws batch submit-job \
  --job-name batch-run \
  --job-queue agentic-batch-queue \
  --job-definition agentic-batch-worker \
  --array-properties size=50
```

Concurrency is capped by the compute environment's `maxvCpus` (16 by default, so
8 concurrent tasks at 2 vCPU each). Many concurrent containers share your
account's Amazon Bedrock throughput, so check your tokens-per-minute quota against
your intended concurrency before a large batch.

## Choosing a model

The model is a job-definition environment variable, not an image setting, so
changing it needs no rebuild. Pass a different `modelId` to the stack, or override
`ANTHROPIC_MODEL` at submission time.

Pin a specific model version rather than an alias. Aliases resolve to the CLI's
built-in default for Amazon Bedrock, and that default changes between releases.
Per-token price is a poor predictor of per-item cost for agentic workloads,
because the number of model calls a run makes dominates the total. Measure on a
sample of your own items before committing.

## Clean up

```bash
cd infrastructure
npx cdk destroy
```

The S3 bucket, its contents, the DynamoDB table, the VPC, the Batch queue and
compute environment, the dashboard, and the log group are all removed. If you adapt
this for anything you care about, change those removal policies to `RETAIN` first.
Note that VPC interface endpoints bill hourly whether or not jobs run, which makes
them the main reason not to leave an idle stack deployed. Confirm that all six
endpoints are gone:

```bash
aws ec2 describe-vpc-endpoints --query 'length(VpcEndpoints)'
```

Four things `cdk destroy` does not remove:

- **The CDK bootstrap resources**, by design, because other CDK projects in the
  account use them.
- **The worker image, roughly 250 MB per build.** This stack creates no Amazon ECR
  repository of its own; the image is a CDK Docker image asset, so it is pushed to
  the shared `cdk-hnb659fds-container-assets-*` repository, and every redeploy adds
  another image. Delete the images there if you are done with the pattern.
- **Two Lambda log groups** created by the CDK's own custom resources, named after
  the stack. They hold no data, but they will look like leftovers when you check.
- **The Amazon EC2 build host**, if you used one. Terminate it separately.

## Repository layout

```
infrastructure/
  app.ts                  CDK app entry point
  stack.ts                the whole stack
  dashboard-body.json     CloudWatch dashboard, with placeholders substituted at synth
  task-role-policy.json   reference copy of the task role permissions
container/
  Dockerfile              worker image: agent CLI + logic, resolved at build time
  worker.sh               the wrapper: fetch, run, parse, upload, record
  agent-logic/            sample agent logic; replace with your own
samples/                  synthetic input documents
```

## Adapting this to another agent CLI

Three requirements: the CLI must run non-interactively, authenticate from the
environment rather than an interactive login, and emit machine-readable output.
Change the invocation in `container/worker.sh`, the installation in
`container/Dockerfile`, and the environment variables in `stack.ts`. Everything
else is unchanged.

"Non-interactively" is stricter than it sounds. The worker passes an explicit
prompt, assembled from the body of `agent-logic/commands/analyze.md`, rather than
invoking that command by name. Slash commands are a feature of interactive
sessions: in the CLI's print mode they are not resolved, and — this is the part
that matters — the run does not fail. It exits zero with the unresolved command
name as its result and no token usage, which a wrapper will happily record as a
successful item. Prefer an explicit prompt, and assume any convenience your agent
offers interactively may be absent in its batch mode until you have proven
otherwise.

Point `COMMAND_FILE` at a different file to change the prompt without touching the
wrapper.

## Security

This is sample code intended for evaluation, not a production deployment. Before
production use, review the removal policies, add encryption with a customer managed
key where your requirements call for it, and confirm service and model eligibility
for any regulated workload against the AWS compliance references.

Additional hardening notes for production use:

- **Container installers are not checksum-pinned.** The Dockerfile fetches the
  Claude Code installer (`curl -fsSL https://claude.ai/install.sh | bash`) and the
  AWS CLI zip over TLS from vendor-controlled hosts. If you need supply-chain
  provenance, pin the AWS CLI zip's published SHA-256 and use a vendor-signed
  Claude Code artifact where one is available.
- **Enable Amazon S3 server access logging.** For production, add a
  `serverAccessLogsBucket` to the data bucket alongside the removal-policy and
  encryption changes noted above.
- **Consider Amazon Bedrock Guardrails.** For workloads whose inputs or outputs
  need content-safety controls, configure an Amazon Bedrock Guardrail on the
  invocation and reference it via `guardrailIdentifier` / `guardrailVersion`.
  See the [Amazon Bedrock Guardrails documentation](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails.html).

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for reporting
security issues.

## License

This library is licensed under the MIT-0 License. See [LICENSE](LICENSE).
