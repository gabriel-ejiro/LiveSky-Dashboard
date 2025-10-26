import os, json, time, urllib.request, boto3
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])
apigw = boto3.client("apigatewaymanagementapi",
    endpoint_url=f"https://{os.environ['API_ID']}.execute-api.{os.environ['REGION']}.amazonaws.com/{os.environ['STAGE']}")

def get_weather():
    # Use Open-Meteo (free, no key). Example: Bratislava lat=48.1486, lon=17.1077
    url = "https://api.open-meteo.com/v1/forecast?latitude=48.1486&longitude=17.1077&current_weather=true"
    with urllib.request.urlopen(url, timeout=8) as r:
        data = json.loads(r.read())
    cw = data.get("current_weather", {})
    return {
        "ts": int(time.time()),
        "temp_c": cw.get("temperature"),
        "windspeed": cw.get("windspeed"),
        "winddir": cw.get("winddirection"),
        "weathercode": cw.get("weathercode")
    }

def handler(event, context):
    weather = get_weather()
    payload = json.dumps({"type": "weather", "data": weather}).encode("utf-8")

    # Scan connections (OK for small scale). For larger scale, use DDB Streams + fanout pattern.
    conns = table.scan().get("Items", [])
    stale = []
    for c in conns:
        try:
            apigw.post_to_connection(ConnectionId=c["connectionId"], Data=payload)
        except apigw.exceptions.GoneException:
            stale.append(c["connectionId"])
        except Exception as e:
            print("post error:", e)

    # cleanup stale connections
    for cid in stale:
        table.delete_item(Key={"connectionId": cid})

    return {"statusCode": 200, "body": f"sent to {len(conns)-len(stale)}"}
