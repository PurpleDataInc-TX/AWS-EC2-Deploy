import boto3
import json

USER = "cloudpi-msa-databricks"
S3_BUCKET = "cloudpi-db-billing"

iam = boto3.client("iam")

# Create the IAM user (ignore if it already exists)
try:
    iam.create_user(UserName=USER)
    print(f"Created IAM user: {USER}")
except iam.exceptions.EntityAlreadyExistsException:
    print(f"IAM user already exists: {USER}")

# Attach read-only S3 policy scoped to the billing bucket
policy = {
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": [
            "s3:GetObject",
            "s3:ListBucket",
            "s3:GetBucketLocation"
        ],
        "Resource": [
            f"arn:aws:s3:::{S3_BUCKET}",
            f"arn:aws:s3:::{S3_BUCKET}/*"
        ]
    }]
}
iam.put_user_policy(
    UserName=USER,
    PolicyName="cloudpi-msa-s3-read",
    PolicyDocument=json.dumps(policy)
)
print("Attached read-only S3 policy")

# Create an access key
key = iam.create_access_key(UserName=USER)["AccessKey"]
print("\n=== MSA CREDENTIALS (paste into CloudPi) ===")
print("Access Key ID    :", key["AccessKeyId"])
print("Secret Access Key:", key["SecretAccessKey"])
print("Region           : us-east-2")

# Print account id for Target Account ID field
acct = boto3.client("sts").get_caller_identity()["Account"]
print("Target Account ID:", acct)
