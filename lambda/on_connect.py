import os, boto3
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])

def handler(event, context):
    connection_id = event["requestContext"]["connectionId"]
    table.put_item(Item={"connectionId": connection_id})
    return {"statusCode": 200, "body": "connected"}
