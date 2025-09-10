# terraform-aws-chainguard-account-association

This module provisions the **AWS-side trust** for Chainguard → AWS OIDC federation and the **IAM roles** Chainguard services use (e.g., Catalog Syncer) to mirror images into your **Amazon ECR**.

> **Note:** This module **does not perform the mirroring itself**. It establishes trust and roles. Tag mirroring is performed by Chainguard’s Catalog Syncer or your own copier process.

---

## Table of Contents

- [Overview](#overview)
- [Usage & Setup Walkthrough](#usage--setup-walkthrough)
  - [Pre-setup Steps](#pre-setup-steps)
    - [1) Prerequisites](#1-prerequisites)
    - [2) Required Information](#2-required-information)
    - [3) Set up Chainguard OIDC Trust to AWS (Chainguard side)](#3-set-up-chainguard-oidc-trust-to-aws-chainguard-side)
  - [Initialize the Terraform Module](#initialize-the-terraform-module)
  - [Create the Terraform Resources](#create-the-terraform-resources)
    - [1) Supplying Inputs](#1-supplying-inputs)
    - [2) Resources Created](#2-resources-created)
- [Verify OIDC Token Trust Exchange](#verify-oidc-token-trust-exchange)
- [Create ECR Destination Repositories](#create-ecr-destination-repositories)
- [Sync Private Catalog to ECR](#sync-private-catalog-to-ecr)
- [Quick Verify (ECR Tags & Images)](#quick-verify-ecr-tags--images)
- [Reference: Minimal Provider & Variables](#reference-minimal-provider--variables)
- [Troubleshooting](#troubleshooting)

---

## Overview

What this module does:

- Creates an **AWS IAM OIDC provider** that trusts Chainguard’s issuer.
- Creates an **IAM role for readiness checks** (canary).
- Creates an **IAM role for the Catalog Syncer** with permissions to **push images and tags** to ECR.
- Attaches the ECR permissions policy to the syncer role.

---

# Usage & Setup Walkthrough

## Pre-setup Steps

### 1) Prerequisites

- Complete the **OIDC setup in Chainguard** (Custom IdP) using the guide:  
  https://edu.chainguard.dev/chainguard/administration/custom-idps/custom-idps/#generic-integration-guide
- AWS CLI installed and authenticated (SSO or keys).
- Terraform installed.

### 2) Required Information

**General Inputs**
- `AWS_PROFILE` – AWS named profile for your shell (optional if using env keys).
- `AWS_REGION` – AWS region to deploy resources.
- `ORG_UID` – Your Chainguard organization UID (from Console settings or `chainctl`).

**Terraform Inputs**
- `group_ids` – One or more Chainguard **group IDs** to bind to your AWS account.
- `account` – Your **AWS account ID**

> **Note:** `group_ids` are Chainguard **group** identifiers and you can include multiple if you have them

### 3) Set up Chainguard OIDC Trust to AWS (Chainguard side)

Register your AWS account with your Chainguard org:

```
chainctl iam account-associations set aws $ORG_UID --account $AWS_ACCOUNT_ID
```

## Initialize the Terraform Module

Use the default main.tf that includes only the module needed

```
module "chainguard-account-association" {
  source = "chainguard-dev/chainguard-account-association/aws"

  group_ids = var.group_ids
  account   = var.account
}
```

Initialize Terraform:

```
terraform init
```

## Create the Terraform Resources

### 1) Supplying Inputs

#### Secrets (AWS Secrets Manager → TF_VAR_ envs in your runner)
```
"secrets": [
  { "name": "TF_VAR_account",   "valueFrom": "arn:aws:secretsmanager:<region>:<acct>:secret:/terraform/chainguard/account-XXXX" },
  { "name": "TF_VAR_group_ids", "valueFrom": "arn:aws:secretsmanager:<region>:<acct>:secret:/terraform/chainguard/group_id-YYYY" }
]
```

#### Terraform CLI variables
```
terraform apply \
  -var='account=<account-id>' \
  -var='group_ids=["<group-id-1>","<group-id-2>"]'
```

#### tfvars file (recommended for local dev)

```
# terraform.tfvars
account   = "123456789012"
group_ids = ["b3afeb8e...c0", "d4e5f6...aa"]
```

### 2) Resources Created

The module creates the following AWS resources:


| Name | Type |
|------|------|
| [aws_iam_openid_connect_provider.chainguard_idp](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.canary_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.catalog-syncer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.catalog-syncer-ecr-push](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |

Summary of Resources:
* An OIDC provider that establishes a trust relationship with Chainguard's OIDC provider
* A role that Chainguard will use to check that access is working correctly
* A role that Chainguard will use to push images to ECR
* A policy that allows that role to push to ECR

## Verify OIDC Token Trust Exchange

Verify your association from the Chainguard side:
```
chainctl iam account-associations check aws $ORG_UID --account $AWS_ACCOUNT_ID
```

Expected result:
|PROVIDER |READY|
|AWS| Ready|

## Create ECR Destination Repositories

Create ECR repositories corresponding to the images you plan to sync:

```
aws ecr create-repository --region $AWS_REGION --repository-name <repo>/<image>
# repeat as needed
```

Replace repo/image with your desired structure. Ensure names align with the images in your private Chainguard org (e.g., those under cgr.dev/company.com).

## Sync Private Catalog to ECR

Once the trust is established and this module is applied:
* A Chainguard engineer will enable/configure the Catalog Syncer to assume the catalog-syncer role in your account.
* New images published to your Chainguard org will be mirrored into:
	- cgr.dev/<your-org> (source),
	- and your AWS ECR repositories (destination).
	- The sync preserves tags (e.g., :latest, :1.2.3) in ECR.

## Quick Verify (ECR Tags & Images)

List image tags in a repository:

```
aws ecr list-images \
  --region $AWS_REGION \
  --repository-name <repo>/<image> \
  --query 'imageIds[*].[imageTag,imageDigest]'
```

Describe images (see tag ↔ digest mapping, timestamps):

```
aws ecr describe-images \
  --region $AWS_REGION \
  --repository-name <repo>/<image> \
  --query 'imageDetails[*].[imageTags,imageDigest,artifactMediaType,manifestMediaType,imagePushedAt]'
```

Inspect the manifest (index vs. single-platform) for a specific tag:

```
aws ecr batch-get-image \
  --region $AWS_REGION \
  --repository-name <repo>/<image> \
  --image-ids imageTag=<tag> \
  --query 'images[0].imageManifest' --output text | jq .
```

## Troubleshooting

### Terraform can’t find AWS credentials
* Use aws sso login --profile <name> and export AWS_PROFILE=<name> (or set env keys).
* Verify with aws sts get-caller-identity.

### Invalid provider configuration” or SSO not picked up
* Ensure a root-level provider "aws" exists.
* Re-run terraform init after adding providers.

### ECR shows only digests (no tags)
* Tag mirroring is performed by the pusher (Chainguard Catalog Syncer). Once enabled and running, tags will appear shortly after digests.
* check repository Image Tag Mutability is MUTABLE if you expect tag updates.

### Verifying that the syncer assumed the role
* Use CloudTrail to look for AssumeRole on arn:aws:iam::<account>:role/chainguard-catalog-syncer and subsequent ecr:PutImage calls.