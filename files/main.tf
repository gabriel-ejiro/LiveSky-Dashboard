terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Who am I? (for ARNs)
data "aws_caller_identity" "current" {}

# ----------------- DynamoDB -----------------
resource "aws_dynamodb_table" "connections" {
  name         = "${var.project}-connections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "connectionId"

  attribute {
    name = "connectionId"
    type = "S"
  }
}

# ----------------- IAM Roles -----------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "${var.project}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Narrowest possible @connections permission (scoped to this API + stage)
# We can reference api+stage because Terraform knows them at plan time.
locals {
  manage_conn_arn = "arn:aws:execute-api:${var.region}:${data.aws_caller_identity.current.account_id}:${aws_apigatewayv2_api.ws.id}/${var.stage}/POST/@connections/*"
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    sid       = "DDBAccess"
    actions   = ["dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:Scan"]
    resources = [aws_dynamodb_table.connections.arn]
  }

  statement {
    sid       = "ManageConnections"
    actions   = ["execute-api:ManageConnections"]
    resources = [local.manage_conn_arn]
  }

  statement {
    sid     = "Logs"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lambda_policy" {
  name   = "${var.project}-lambda-policy"
  policy = data.aws_iam_policy_document.lambda_policy.json
}

resource "aws_iam_role_policy_attachment" "lambda_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# ----------------- WebSocket API -----------------
resource "aws_apigatewayv2_api" "ws" {
  name                       = "${var.project}-ws"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}

# ----------------- Lambdas -----------------
resource "aws_lambda_function" "on_connect" {
  function_name = "${var.project}-onconnect"
  role          = aws_iam_role.lambda_role.arn
  handler       = "on_connect.handler"
  runtime       = "python3.11"
  filename      = "lambda/on_connect.zip"
  # optional but recommended so TF knows when to update code:
  # source_code_hash = filebase64sha256("lambda/on_connect.zip")

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.connections.name
    }
  }
}

resource "aws_lambda_function" "on_disconnect" {
  function_name = "${var.project}-ondisconnect"
  role          = aws_iam_role.lambda_role.arn
  handler       = "on_disconnect.handler"
  runtime       = "python3.11"
  filename      = "lambda/on_disconnect.zip"
  # source_code_hash = filebase64sha256("lambda/on_disconnect.zip")

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.connections.name
    }
  }
}

resource "aws_lambda_function" "broadcast" {
  function_name = "${var.project}-broadcast"
  role          = aws_iam_role.lambda_role.arn
  handler       = "broadcast.handler"
  runtime       = "python3.11"
  filename      = "lambda/broadcast.zip"
  # source_code_hash = filebase64sha256("lambda/broadcast.zip")

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.connections.name
      REGION     = var.region
      STAGE      = var.stage
      API_ID     = aws_apigatewayv2_api.ws.id
    }
  }
}

# ----------------- Integrations -----------------
resource "aws_apigatewayv2_integration" "connect_integ" {
  api_id                 = aws_apigatewayv2_api.ws.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.on_connect.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "disconnect_integ" {
  api_id                 = aws_apigatewayv2_api.ws.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.on_disconnect.invoke_arn
  payload_format_version = "2.0"
}

# ----------------- Routes -----------------
resource "aws_apigatewayv2_route" "connect" {
  api_id    = aws_apigatewayv2_api.ws.id
  route_key = "$connect"
  target    = "integrations/${aws_apigatewayv2_integration.connect_integ.id}"
}

resource "aws_apigatewayv2_route" "disconnect" {
  api_id    = aws_apigatewayv2_api.ws.id
  route_key = "$disconnect"
  target    = "integrations/${aws_apigatewayv2_integration.disconnect_integ.id}"
}

# ----------------- Permissions (API Gateway -> Lambdas) -----------------
# For WebSocket routes, scope to route specifically.
resource "aws_lambda_permission" "apigw_connect" {
  statement_id  = "AllowConnectInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.on_connect.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.ws.execution_arn}/*/$connect"
}

resource "aws_lambda_permission" "apigw_disconnect" {
  statement_id  = "AllowDisconnectInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.on_disconnect.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.ws.execution_arn}/*/$disconnect"
}

# ----------------- Stage -----------------
resource "aws_apigatewayv2_stage" "stage" {
  api_id      = aws_apigatewayv2_api.ws.id
  name        = var.stage
  auto_deploy = true
}

# ----------------- EventBridge (Scheduled broadcast) -----------------
resource "aws_cloudwatch_event_rule" "every5" {
  name                = "${var.project}-every5"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "broadcast_target" {
  rule      = aws_cloudwatch_event_rule.every5.name
  target_id = "broadcast"
  arn       = aws_lambda_function.broadcast.arn
}

resource "aws_lambda_permission" "allow_events" {
  statement_id  = "AllowEventInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.broadcast.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every5.arn
}

# --------------- S3 Static Site ---------------
resource "aws_s3_bucket" "site" {
  bucket = "${var.project}-site-${var.region}"
}

resource "aws_s3_bucket_public_access_block" "site_pab" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "site_policy" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "PublicRead",
      Effect    = "Allow",
      Principal = "*",
      Action    = ["s3:GetObject"],
      Resource  = ["${aws_s3_bucket.site.arn}/*"]
    }]
  })
}

resource "aws_s3_bucket_website_configuration" "site_web" {
  bucket = aws_s3_bucket.site.id

  index_document {
    suffix = "index.html"
  }
}

# --------------- Outputs ---------------
output "websocket_wss_url" {
  value = "wss://${replace(aws_apigatewayv2_api.ws.api_endpoint, "https://", "")}/${var.stage}"
}

output "site_url" {
  value = "http://${aws_s3_bucket_website_configuration.site_web.website_endpoint}"
}

