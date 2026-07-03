import boto3

REGION = "us-east-2"
S3_BUCKET = "cloudpi-db-billing"

s3 = boto3.client("s3", region_name=REGION)

# Create bucket (us-east-2 requires LocationConstraint)
s3.create_bucket(
    Bucket=S3_BUCKET,
    CreateBucketConfiguration={"LocationConstraint": REGION}
)

# Block public access
s3.put_public_access_block(
    Bucket=S3_BUCKET,
    PublicAccessBlockConfiguration={
        "BlockPublicAcls": True,
        "IgnorePublicAcls": True,
        "BlockPublicPolicy": True,
        "RestrictPublicBuckets": True
    }
)

# Enable SSE-S3 encryption
s3.put_bucket_encryption(
    Bucket=S3_BUCKET,
    ServerSideEncryptionConfiguration={
        "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
    }
)

print("Bucket created: s3://" + S3_BUCKET)
print("Public access blocked")
print("Encryption enabled")
