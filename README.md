flowchart LR
A[S3 Static Site\nindex.html] -- wss --> B[API Gateway WebSocket\nRoutes: $connect/$disconnect/sendmessage]
B <---> C[Lambda on_connect / on_disconnect]
C <--> D[(DynamoDB\nws_connections)]
E[EventBridge\nrate(5m)] --> F[Lambda broadcast_weather]
F -->|API Gateway Mgmt API\nPOST @connections| B
