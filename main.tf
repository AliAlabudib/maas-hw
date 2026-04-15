terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ---------- DynamoDB ----------
resource "aws_dynamodb_table" "results" {
  name         = "pi-results"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }
}

# ---------- IAM Role for Lambdas ----------
resource "aws_iam_role" "lambda_role" {
  name = "maas-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "maas-lambda-policy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:*"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.results.arn
      }
    ]
  })
}

# ---------- EventBridge ----------
resource "aws_cloudwatch_event_bus" "maas_bus" {
  name = "maas-event-bus"
}

# ---------- Receiver Lambda ----------
data "archive_file" "receiver_zip" {
  type        = "zip"
  source_file = "${path.module}/receiver/app.py"
  output_path = "${path.module}/receiver.zip"
}

resource "aws_lambda_function" "receiver" {
  function_name    = "maas-receiver"
  role             = aws_iam_role.lambda_role.arn
  handler          = "app.lambda_handler"
  runtime          = "python3.11"
  filename         = data.archive_file.receiver_zip.output_path
  source_code_hash = data.archive_file.receiver_zip.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      EVENT_BUS_NAME = aws_cloudwatch_event_bus.maas_bus.name
    }
  }
}

# ---------- Simulator Lambda ----------
data "archive_file" "simulator_zip" {
  type        = "zip"
  source_file = "${path.module}/simulator/app.py"
  output_path = "${path.module}/simulator.zip"
}

resource "aws_lambda_function" "simulator" {
  function_name    = "maas-simulator"
  role             = aws_iam_role.lambda_role.arn
  handler          = "app.lambda_handler"
  runtime          = "python3.11"
  filename         = data.archive_file.simulator_zip.output_path
  source_code_hash = data.archive_file.simulator_zip.output_base64sha256
  timeout          = 300

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.results.name
    }
  }
}

# ---------- EventBridge Rule → Simulator ----------
resource "aws_cloudwatch_event_rule" "simulation_rule" {
  name           = "maas-simulation-rule"
  event_bus_name = aws_cloudwatch_event_bus.maas_bus.name
  event_pattern = jsonencode({
    source      = ["maas.receiver"]
    detail-type = ["SimulationRequested"]
  })
}

resource "aws_cloudwatch_event_target" "simulator_target" {
  rule           = aws_cloudwatch_event_rule.simulation_rule.name
  event_bus_name = aws_cloudwatch_event_bus.maas_bus.name
  target_id      = "SimulatorLambda"
  arn            = aws_lambda_function.simulator.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.simulator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.simulation_rule.arn
}

# ---------- API Gateway ----------
resource "aws_apigatewayv2_api" "maas_api" {
  name          = "maas-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "receiver_integration" {
  api_id                 = aws_apigatewayv2_api.maas_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.receiver.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "estimate_pi" {
  api_id    = aws_apigatewayv2_api.maas_api.id
  route_key = "POST /estimate_pi"
  target    = "integrations/${aws_apigatewayv2_integration.receiver_integration.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.maas_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGW"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.receiver.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.maas_api.execution_arn}/*/*"
}

# ---------- Output ----------
output "api_url" {
  value = aws_apigatewayv2_stage.default.invoke_url
}
