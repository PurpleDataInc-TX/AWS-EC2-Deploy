import boto3
import json

IAM_ROLE = "cloudpi-databricks-role"

# Trust policy without ExternalId condition - Serverless UC may use different ExternalId
trust = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::414351767826:role/unity-catalog-prod-UCMasterRole-14S5ZJVKOTYTL"
            },
            "Action": "sts:AssumeRole",
            "Condition": {
                "StringEquals": {
                    "sts:ExternalId": "0ac80853-98c4-4ba6-9da5-4b94db051422"
                }
            }
        },
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::414351767826:root"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}

iam = boto3.client("iam")
iam.update_assume_role_policy(
    RoleName=IAM_ROLE,
    PolicyDocument=json.dumps(trust)
)
print("Trust policy updated - added Databricks account root as principal")
print("Role ARN: arn:aws:iam::887514555091:role/cloudpi-databricks-role")
