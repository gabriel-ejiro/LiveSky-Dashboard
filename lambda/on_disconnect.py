import os, json, boto3

TABLE = os.environ.get("TABLE_NAME")
ddb = boto3.resource("dynamodb")
table = ddb.Table(TABLE) if TABLE else None

def handler(event, context):
    # Log safely
    try:
        print("DISCONNECT EVENT:", json.dumps(event))
    except Exception as e:
        print("LOG ERROR:", str(e))

    # connectionId only exists when invoked by API Gateway
    connection_id = (event.get("requestContext") or {}).get("connectionId")

    if table and connection_id:
        try:
            table.delete_item(Key={"connectionId": connection_id})
            print(f"Deleted connection: {connection_id}")
        except Exception as e:
            # Never raise—still return 200 so the disconnect completes cleanly
            print("DDB delete error:", str(e))

    return {"statusCode": 200, "body": "disconnected"}

