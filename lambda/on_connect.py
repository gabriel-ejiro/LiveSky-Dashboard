import os, json, boto3

TABLE = os.getenv("TABLE_NAME")
dynamodb = boto3.resource("dynamodb") if TABLE else None
table = dynamodb.Table(TABLE) if TABLE else None

def handler(event, context):
    # Log exactly what we got from API Gateway
    try:
        print("RAW CONNECT EVENT:", json.dumps(event))
    except Exception:
        print("RAW CONNECT EVENT (non-serializable):", str(event))

    # Get connectionId safely
    rc = (event or {}).get("requestContext", {}) or {}
    connection_id = rc.get("connectionId")

    # If no connectionId (unexpected on real $connect), just succeed
    if not connection_id:
        return {"statusCode": 200, "body": json.dumps({"ok": True, "note": "no connectionId"})}

    # Record the connection (do not fail handshake if DDB errors)
    try:
        if table:
            table.put_item(Item={"connectionId": connection_id})
    except Exception as e:
        print("DDB put error:", repr(e))

    return {"statusCode": 200, "body": "connected"}

