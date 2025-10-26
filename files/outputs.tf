output "api_id" {
  value = aws_apigatewayv2_api.ws.id
}

output "stage" {
  value = var.stage
}
output "websocket_url" {
  value = "wss://${replace(aws_apigatewayv2_api.ws.api_endpoint, "https://", "")}/${var.stage}"
}

output "manage_connections_arn" {
  value = "arn:aws:execute-api:${var.region}:${data.aws_caller_identity.current.account_id}:${aws_apigatewayv2_api.ws.id}/${var.stage}/POST/@connections/*"
}
