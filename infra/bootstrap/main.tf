# Applied once per AWS account, from a laptop, by scripts/aws.sh bootstrap.
# It makes the two things GitHub Actions needs before it can deploy infra/:
# a bucket for Terraform's state, and a role it can take on without a stored key.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project      = "beer-sales"
      environment  = "bootstrap"
      "managed-by" = "terraform"
    }
  }
}

variable "region" {
  description = "AWS region the job is deployed into"
  type        = string
  default     = "eu-west-2"
}

variable "github_repository" {
  description = "The owner/name of the GitHub repository allowed to deploy"
  type        = string
}

variable "github_branch" {
  description = "The only branch whose workflows may take on the deploy role"
  type        = string
  default     = "main"
}

variable "create_oidc_provider" {
  description = "Whether to create GitHub's identity provider; false when the account already has it"
  type        = bool
  default     = true
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name       = "beer-sales"
  account    = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  github_url = "token.actions.githubusercontent.com"
  provider_arn = (
    var.create_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : "arn:${local.partition}:iam::${local.account}:oidc-provider/${local.github_url}"
  )
  state_bucket = "${local.name}-tfstate-${local.account}-${var.region}"
  # The name infra/ gives the data bucket when it is left to choose.
  data_bucket = "${local.name}-${local.account}-${var.region}"
}

# --- Terraform state ---

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket
  # So that removing the bootstrap is one command, old versions and all.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- GitHub's identity, and who may use it ---

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://${local.github_url}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    # One repository and one branch. A pull request, or a fork, gets nothing.
    condition {
      test     = "StringEquals"
      variable = "${local.github_url}:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${local.name}-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = 3600
}

# --- What the role may do: build infra/, push the image, load the events, run the job ---

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "TerraformState"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "DataBucket"
    actions   = ["s3:*"]
    resources = ["arn:${local.partition}:s3:::${local.data_bucket}", "arn:${local.partition}:s3:::${local.data_bucket}/*"]
  }

  # The bucket is made through Cloud Control, which is CloudFormation's API underneath.
  statement {
    sid = "CloudControl"
    actions = [
      "cloudformation:CreateResource",
      "cloudformation:GetResource",
      "cloudformation:UpdateResource",
      "cloudformation:DeleteResource",
      "cloudformation:GetResourceRequestStatus",
      "cloudformation:ListResources",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "Registry"
    actions   = ["ecr:*"]
    resources = ["arn:${local.partition}:ecr:${var.region}:${local.account}:repository/${local.name}"]
  }

  statement {
    sid       = "RegistryLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid     = "Roles"
    actions = ["iam:*"]
    resources = [
      "arn:${local.partition}:iam::${local.account}:role/${local.name}-execution",
      "arn:${local.partition}:iam::${local.account}:role/${local.name}-task",
      "arn:${local.partition}:iam::${local.account}:role/${local.name}-scheduler",
    ]
  }

  statement {
    sid     = "JobAndSchedule"
    actions = ["ecs:*", "scheduler:*", "events:*", "sns:*", "logs:*", "resource-groups:*"]
    resources = [
      "arn:${local.partition}:ecs:${var.region}:${local.account}:*",
      "arn:${local.partition}:scheduler:${var.region}:${local.account}:schedule/default/${local.name}",
      "arn:${local.partition}:events:${var.region}:${local.account}:rule/${local.name}-failed",
      "arn:${local.partition}:sns:${var.region}:${local.account}:${local.name}-alerts",
      "arn:${local.partition}:sns:${var.region}:${local.account}:${local.name}-alerts:*",
      "arn:${local.partition}:logs:${var.region}:${local.account}:log-group:/ecs/${local.name}",
      "arn:${local.partition}:logs:${var.region}:${local.account}:log-group:/ecs/${local.name}:*",
      "arn:${local.partition}:resource-groups:${var.region}:${local.account}:group/${local.name}-*",
    ]
  }

  # Lookups and the few calls that AWS does not let a policy pin to one resource.
  statement {
    sid = "Unscoped"
    actions = [
      "sts:GetCallerIdentity",
      "ec2:Describe*",
      "ec2:CreateSecurityGroup",
      "ec2:CreateTags",
      "ecs:RegisterTaskDefinition",
      "ecs:DeregisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:ListTaskDefinitions",
      "logs:DescribeLogGroups",
      "sns:GetSubscriptionAttributes",
      "sns:Unsubscribe",
      "scheduler:ListSchedules",
      "tag:GetResources",
      "cloudformation:DescribeStacks",
      "cloudformation:ListStackResources",
      "resource-groups:ListGroups",
    ]
    resources = ["*"]
  }

  statement {
    sid = "SecurityGroup"
    actions = [
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:DeleteTags",
    ]
    resources = ["arn:${local.partition}:ec2:${var.region}:${local.account}:security-group/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/project"
      values   = [local.name]
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy-beer-sales"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "deploy_role_arn" {
  value = aws_iam_role.deploy.arn
}
