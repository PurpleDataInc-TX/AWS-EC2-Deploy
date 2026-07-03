import boto3
import json

IAM_ROLE = "cloudpi-databricks-role"
EXTERNAL_ID = "0ac80853-98c4-4ba6-9da5-4b94db051422"

trust = {
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {
            "AWS": [
                "arn:aws:iam::414351767826:role/unity-catalog-prod-UCMasterRole-14S5ZJVKOTYTL",
                "arn:aws:iam::887514555091:role/cloudpi-databricks-role"
            ]
        },
        "Action": "sts:AssumeRole",
        "Condition": {
            "StringEquals": {
                "sts:ExternalId": EXTERNAL_ID
            }
        }
    }]
}

iam = boto3.client("iam")
iam.update_assume_role_policy(
    RoleName=IAM_ROLE,
    PolicyDocument=json.dumps(trust)
)
print("Trust policy updated with External ID:", EXTERNAL_ID)
