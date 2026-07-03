import boto3
import json

REGION = "us-east-2"
S3_BUCKET = "cloudpi-db-billing"
IAM_ROLE = "cloudpi-databricks-role"

iam = boto3.client("iam")

# Create role with placeholder trust policy (Databricks gives the real one in Stage 4)
trust = {
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {
            "AWS": "arn:aws:iam::414351767826:role/unity-catalog-prod-UCMasterRole-14S5ZJVKOTYTL"
        },
        "Action": "sts:AssumeRole",
        "Condition": {
            "StringEquals": {"sts:ExternalId": "PLACEHOLDER"}
        }
    }]
}

role = iam.create_role(
    RoleName=IAM_ROLE,
    AssumeRolePolicyDocument=json.dumps(trust),
    Description="Databricks Unity Catalog access to CloudPi S3"
)
role_arn = role["Role"]["Arn"]
print("Role ARN:", role_arn)

# Attach S3 policy
policy = {
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:ListBucket",
            "s3:GetBucketLocation"
        ],
        "Resource": [
            f"arn:aws:s3:::{S3_BUCKET}",
            f"arn:aws:s3:::{S3_BUCKET}/*"
        ]
    }]
}

iam.put_role_policy(
    RoleName=IAM_ROLE,
    PolicyName="cloudpi-s3-access",
    PolicyDocument=json.dumps(policy)
)

print("S3 policy attached")
print("SAVE THIS ROLE ARN - you will need it in Stage 4")
