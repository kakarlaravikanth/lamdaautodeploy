# terraform/main.tf
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
  
  backend "s3" {
    # Configure this with your S3 bucket for state storage
    bucket = "your-terraform-state-bucket"
    key    = "fastapi-app/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# Data sources
data "aws_caller_identity" "current" {}

# S3 bucket for deployment artifacts
resource "aws_s3_bucket" "deployment_artifacts" {
  bucket = "${var.project_name}-deployment-artifacts-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "${var.project_name}-deployment-artifacts"
    Environment = var.environment
  }
}

resource "random_id" "bucket_suffix" {
  byte_length = 8
}

resource "aws_s3_bucket_versioning" "deployment_artifacts_versioning" {
  bucket = aws_s3_bucket.deployment_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "deployment_artifacts_encryption" {
  bucket = aws_s3_bucket.deployment_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# IAM role for Lambda execution
resource "aws_iam_role" "lambda_execution_role" {
  name = "${var.project_name}-lambda-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-lambda-execution-role"
    Environment = var.environment
  }
}

# IAM policy for Lambda execution
resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.project_name}"
  retention_in_days = 7

  tags = {
    Name        = "${var.project_name}-logs"
    Environment = var.environment
  }
}

# Lambda function
resource "aws_lambda_function" "fastapi_lambda" {
  filename         = var.lambda_zip_path
  function_name    = var.project_name
  role            = aws_iam_role.lambda_execution_role.arn
  handler         = "app.main.handler"
  runtime         = "python3.11"
  timeout         = 30
  memory_size     = 256

  environment {
    variables = {
      ENVIRONMENT = var.environment
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_policy,
    aws_cloudwatch_log_group.lambda_logs,
  ]

  tags = {
    Name        = "${var.project_name}-lambda"
    Environment = var.environment
  }
}

# API Gateway
resource "aws_api_gateway_rest_api" "fastapi_api" {
  name        = "${var.project_name}-api"
  description = "API Gateway for FastAPI application"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name        = "${var.project_name}-api"
    Environment = var.environment
  }
}

# API Gateway Resource (catch-all)
resource "aws_api_gateway_resource" "fastapi_resource" {
  rest_api_id = aws_api_gateway_rest_api.fastapi_api.id
  parent_id   = aws_api_gateway_rest_api.fastapi_api.root_resource_id
  path_part   = "{proxy+}"
}

# API Gateway Method (ANY)
resource "aws_api_gateway_method" "fastapi_method" {
  rest_api_id   = aws_api_gateway_rest_api.fastapi_api.id
  resource_id   = aws_api_gateway_resource.fastapi_resource.id
  http_method   = "ANY"
  authorization = "NONE"
}

# API Gateway Method (root)
resource "aws_api_gateway_method" "fastapi_method_root" {
  rest_api_id   = aws_api_gateway_rest_api.fastapi_api.id
  resource_id   = aws_api_gateway_rest_api.fastapi_api.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

# API Gateway Integration
resource "aws_api_gateway_integration" "fastapi_integration" {
  rest_api_id = aws_api_gateway_rest_api.fastapi_api.id
  resource_id = aws_api_gateway_resource.fastapi_resource.id
  http_method = aws_api_gateway_method.fastapi_method.http_method

  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.fastapi_lambda.invoke_arn
}

# API Gateway Integration (root)
resource "aws_api_gateway_integration" "fastapi_integration_root" {
  rest_api_id = aws_api_gateway_rest_api.fastapi_api.id
  resource_id = aws_api_gateway_rest_api.fastapi_api.root_resource_id
  http_method = aws_api_gateway_method.fastapi_method_root.http_method

  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.fastapi_lambda.invoke_arn
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fastapi_lambda.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.fastapi_api.execution_arn}/*/*"
}

# API Gateway Deployment
resource "aws_api_gateway_deployment" "fastapi_deployment" {
  depends_on = [
    aws_api_gateway_integration.fastapi_integration,
    aws_api_gateway_integration.fastapi_integration_root,
  ]

  rest_api_id = aws_api_gateway_rest_api.fastapi_api.id
  stage_name  = var.environment

  lifecycle {
    create_before_destroy = true
  }
}

# API Gateway Stage
resource "aws_api_gateway_stage" "fastapi_stage" {
  deployment_id = aws_api_gateway_deployment.fastapi_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.fastapi_api.id
  stage_name    = var.environment

  tags = {
    Name        = "${var.project_name}-stage-${var.environment}"
    Environment = var.environment
  }
}

# API Gateway Method Settings
resource "aws_api_gateway_method_settings" "fastapi_settings" {
  rest_api_id = aws_api_gateway_rest_api.fastapi_api.id
  stage_name  = aws_api_gateway_stage.fastapi_stage.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled = true
    logging_level   = "INFO"
  }
}