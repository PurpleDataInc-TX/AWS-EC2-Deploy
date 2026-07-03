import boto3
import json

IAM_ROLE = "cloudpi-databricks-role"
S3_BUCKET = "cloudpi-db-billing"

iam = boto3.client("iam")

# Updated S3 policy with full permissions including notification config
policy = {
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:ListBucket",
            "s3:GetBucketLocation",
            "s3:GetBucketNotification",
            "s3:PutBucketNotification",
            "s3:GetLifecycleConfiguration",
            "s3:PutLifecycleConfiguration"
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
print("IAM policy updated with full S3 permissions")
