#!/usr/bin/env node
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { AgenticBatchStack } from './stack';

const app = new cdk.App();

new AgenticBatchStack(app, 'AgenticBatchStack', {
  projectName: 'agentic-batch',
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
  description:
    'Run an existing agent CLI at scale on AWS Batch with Amazon Bedrock (one container per work item)',
});

app.synth();
