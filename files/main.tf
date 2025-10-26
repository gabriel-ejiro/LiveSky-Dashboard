terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

# ----------------- DynamoDB -----------------
resource "aws_dynamodb_table" "connections" {
  name         = "${var.project}-connections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "connectionId"

  attribute { name = "connectionId"; type = "S" }
}

# ----------------- IAM Roles -----------------
data "aws_iam_policy_document" "lambda_assume" {
  statement { actions = ["sts:AssumeRole"]; principals { type = "service"; identifiers = ["lambda.amazonaws.com"] } }
}

resource "aws_iam_role" "lambda_role" {
  name               = "${var.project}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    sid     = "DDBAccess"
    actions = ["dynamodb:PutItem","dynamodb:DeleteItem","dynamodb:Scan"]
    resources = [aws_dynamodb_table.connections.arn]
  }
  statement {
    sid     = "ManageConnections"
    actions = ["execute-api:ManageConnections"]
    resources = ["arn:aws:execute-api:${var.region}:*:*/*/POST/@connections/*"]
  }
  statement {
    sid     = "Logs"
    actions = ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"]
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

# Lambdas
resource "aws_lambda_function" "on_connect" {
  function_name = "${var.project}-onconnect"
  role          = aws_iam_role.lambda_role.arn
  handler       = "on_connect.handler"
  runtime       = "python3.11"
  filename      = "lambda/on_connect.zip"
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
  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.connections.name
      REGION     = var.region
      STAGE      = var.stage
      # API_ID filled after stage creation via environment update below
      API_ID     = ""
    }
  }
}

# Integrations
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

# Routes
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

# Permissions for API Gateway to call Lambdas
resource "aws_lambda_permission" "apigw_connect" {
  statement_id  = "AllowConnectInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.on_connect.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.ws.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_disconnect" {
  statement_id  = "AllowDisconnectInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.on_disconnect.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.ws.execution_arn}/*/*"
}

# Stage + Deployment
resource "aws_apigatewayv2_stage" "stage" {
  api_id      = aws_apigatewayv2_api.ws.id
  name        = var.stage
  auto_deploy = true
}

# Now that API exists, inject API_ID into broadcast Lambda env
resource "aws_lambda_function_event_invoke_config" "broadcast_async" {
  function_name = aws_lambda_function.broadcast.function_name
  maximum_retry_attempts = 0
}

resource "aws_lambda_environment" "broadcast_env_update" {
  # (Uses Terraform 'replace' pattern via a null_resource + triggers)
}

# Simpler: update broadcast's env inline by recreating it when API is ready:
resource "aws_lambda_alias" "broadcast_alias" {
  name             = "live"
  function_name    = aws_lambda_function.broadcast.arn
  function_version = "$LATEST"
  provisioned_concurrent_executions = 0

  lifecycle { ignore_changes = [provisioned_concurrent_executions] }
}

resource "aws_lambda_provisioned_concurrency_config" "noop" {
  # dummy to ensure apply order; not strictly needed
  function_name = aws_lambda_alias.broadcast_alias.function_name
  qualifier     = aws_lambda_alias.broadcast_alias.name
  provisioned_concurrent_executions = 0
  lifecycle { ignore_changes = [provisioned_concurrent_executions] }
}

# EventBridge scheduler
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
      Sid = "PublicRead",
      Effect = "Allow",
      Principal = "*",
      Action = ["s3:GetObject"],
      Resource = ["${aws_s3_bucket.site.arn}/*"]
    }]
  })
}

resource "aws_s3_bucket_website_configuration" "site_web" {
  bucket = aws_s3_bucket.site.id
  index_document { suffix = "index.html" }
}

# --------------- Outputs ---------------
output "websocket_wss_url" {
  value = "wss://${aws_apigatewayv2_api.ws.api_endpoint.replace("https://","")}/${var.stage}"
}

output "site_url" {
  value = "http://${aws_s3_bucket_website_configuration.site_web.website_endpoint}"
}
