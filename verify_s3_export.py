import boto3

S3_BUCKET = "cloudpi-db-billing"
FOLDER = "org=1/cloud=aws/source=system_tables"

s3 = boto3.client("s3", region_name="us-east-2")

# Check root _SUCCESS marker
root = s3.list_objects_v2(Bucket=S3_BUCKET, Prefix=f"{FOLDER}/_SUCCESS")
print("Root _SUCCESS:", "FOUND" if root.get("KeyCount", 0) > 0 else "MISSING")
print()

tables = [
    "billing_usage", "list_prices", "clusters", "warehouses", "jobs",
    "workspaces", "node_timeline", "warehouse_events",
    "job_run_timeline", "query_history"
]

print(f"{'TABLE':<20} {'FILES':>6} {'BYTES':>14}")
print("-" * 42)
for t in tables:
    prefix = f"{FOLDER}/table={t}/"
    resp = s3.list_objects_v2(Bucket=S3_BUCKET, Prefix=prefix)
    objs = resp.get("Contents", [])
    count = len(objs)
    size = sum(o["Size"] for o in objs)
    flag = "OK" if count > 0 else "MISSING"
    print(f"{t:<20} {count:>6} {size:>14,}  {flag}")
