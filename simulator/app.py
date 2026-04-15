import json
import boto3
import random
import uuid
import os
from datetime import datetime

def estimate_pi(n):
    inside_circle = 0
    for _ in range(n):
        x, y = random.uniform(-1, 1), random.uniform(-1, 1)
        if x**2 + y**2 <= 1:
            inside_circle += 1
    return (4 * inside_circle) / n

def lambda_handler(event, context):
    detail = event.get("detail", {})
    total_points = detail.get("total_points", 1000000)
    job_id = detail.get("job_id", str(uuid.uuid4()))
    
    pi_estimate = estimate_pi(total_points)
    
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(os.environ["DYNAMODB_TABLE"])
    
    table.put_item(Item={
        "job_id": job_id,
        "total_points": total_points,
        "pi_estimate": str(pi_estimate),
        "timestamp": datetime.utcnow().isoformat()
    })
    
    return {"job_id": job_id, "pi_estimate": pi_estimate}
