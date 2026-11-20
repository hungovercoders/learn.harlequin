terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.0"
    }
  }
}

provider "aws" {
  region = var.region
}

provider "awscc" {
  region = var.region
}

variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-2"
}

variable "bucket_name" {
  description = "Globally unique name for the S3 bucket holding raw events and the summary export"
  type        = string
}

variable "image_tag" {
  description = "Tag of the image in ECR that the task runs"
  type        = string
  default     = "latest"
}

variable "schedule" {
  description = "EventBridge Scheduler expression for the dbt build"
  type        = string
  default     = "cron(0 6 * * ? *)"
}

variable "alert_email" {
  description = "Email address told when the job fails; leave empty to create the topic with no subscriber"
  type        = string
  default     = ""
}

locals {
  name             = "beer-sales"
  events_location  = "s3://${var.bucket_name}/raw/events/*.parquet"
  summary_location = "s3://${var.bucket_name}/summary/daily_event_summary.parquet"
}

# --- Storage -----------------------------------------------------------------

# Made through Cloud Control rather than aws_s3_bucket, which reads the bucket's
# tags through S3 Control. AWS Emulator does not serve that, so the plain
# resource never finishes there. This one applies to the emulator and to AWS.
# It has no force_destroy: empty the bucket before a terraform destroy.
resource "awscc_s3_bucket" "data" {
  bucket_name = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = awscc_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Image and logs ----------------------------------------------------------

resource "aws_ecr_repository" "job" {
  name         = local.name
  force_delete = true
}

resource "aws_cloudwatch_log_group" "job" {
  name              = "/ecs/${local.name}"
  retention_in_days = 14
}

# --- IAM ---------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Lets ECS pull the image and write logs. Nothing to do with our data.
resource "aws_iam_role" "execution" {
  name               = "${local.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# What dbt runs as: read raw events, read and write the summary, nothing else.
resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "task" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [awscc_s3_bucket.data.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["raw/events/*", "summary/*"]
    }
  }

  statement {
    actions   = ["s3:GetObject"]
    resources = ["${awscc_s3_bucket.data.arn}/raw/events/*"]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${awscc_s3_bucket.data.arn}/summary/*"]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "s3-least-privilege"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# --- The job -----------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = local.name
}

resource "aws_ecs_task_definition" "job" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 1024
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "dbt"
      image     = "${aws_ecr_repository.job.repository_url}:${var.image_tag}"
      essential = true
      environment = [
        { name = "DBT_TARGET", value = "s3" },
        { name = "AWS_REGION", value = var.region },
        { name = "EVENTS_LOCATION", value = local.events_location },
        { name = "SUMMARY_LOCATION", value = local.summary_location },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.job.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "dbt"
        }
      }
    }
  ])
}

# --- Networking: the default VPC, outbound only ------------------------------

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "job" {
  name        = local.name
  description = "Outbound only for the beer sales dbt job"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Schedule ----------------------------------------------------------------

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["ecs:RunTask"]
    resources = ["${aws_ecs_task_definition.job.arn_without_revision}:*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.this.arn]
    }
  }

  statement {
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.execution.arn, aws_iam_role.task.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "run-task"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "job" {
  name                = local.name
  schedule_expression = var.schedule

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_ecs_cluster.this.arn
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.job.arn_without_revision
      launch_type         = "FARGATE"

      network_configuration {
        # A public IP lets the task reach ECR and S3 without a NAT gateway.
        assign_public_ip = true
        subnets          = data.aws_subnets.default.ids
        security_groups  = [aws_security_group.job.id]
      }
    }
  }
}

# --- Failure notifications ---------------------------------------------------
# dbt build exits non-zero when a model or test fails, so the container's exit
# code is the signal. A task that never started has no exit code, only a stop code.

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_event_rule" "job_failed" {
  name        = "${local.name}-failed"
  description = "The beer sales dbt job stopped with a non-zero exit code or failed to start"

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.this.arn]
      lastStatus = ["STOPPED"]
      "$or" = [
        { containers = { exitCode = [{ anything-but = 0 }] } },
        { stopCode = ["TaskFailedToStart"] },
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "job_failed" {
  rule = aws_cloudwatch_event_rule.job_failed.name
  arn  = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      task   = "$.detail.taskArn"
      code   = "$.detail.stopCode"
      reason = "$.detail.stoppedReason"
    }
    input_template = "\"The beer-sales dbt job failed. Stop code: <code>. Reason: <reason>. Task: <task>. Logs are in the ${aws_cloudwatch_log_group.job.name} log group.\""
  }
}

data "aws_iam_policy_document" "alerts" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.job_failed.arn]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

# --- Outputs -----------------------------------------------------------------

output "bucket" {
  value = awscc_s3_bucket.data.bucket_name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.job.repository_url
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "events_location" {
  value = local.events_location
}

output "summary_location" {
  value = local.summary_location
}

output "run_task_command" {
  description = "Kick the job off by hand instead of waiting for the schedule"
  value = join(" ", [
    "aws ecs run-task",
    "--region ${var.region}",
    "--cluster ${aws_ecs_cluster.this.name}",
    "--task-definition ${aws_ecs_task_definition.job.family}",
    "--launch-type FARGATE",
    "--network-configuration 'awsvpcConfiguration={subnets=[${join(",", data.aws_subnets.default.ids)}],securityGroups=[${aws_security_group.job.id}],assignPublicIp=ENABLED}'",
  ])
}
