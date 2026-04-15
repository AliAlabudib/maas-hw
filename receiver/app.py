import json
import boto3
import uuid
import os

def lambda_handler(event, context):
    body = json.loads(event.get("body", "{}"))
    total_points = body.get("total_points", 1000000)
    
    client = boto3.client("events")
    client.put_events(
        Entries=[
            {
                "Source": "maas.receiver",
                "DetailType": "SimulationRequested",
                "Detail": json.dumps({
                    "job_id": str(uuid.uuid4()),
                    "total_points": total_points
                }),
                "EventBusName": os.environ["EVENT_BUS_NAME"]
            }
        ]
    )
    
    return {
        "statusCode": 202,
        "body": json.dumps({"message": "Accepted"})
    }
