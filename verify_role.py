import boto3
import json

IAM_ROLE = "cloudpi-databricks-role"
iam = boto3.client("iam")

print("=== TRUST POLICY ===")
role = iam.get_role(RoleName=IAM_ROLE)
print(json.dumps(role["Role"]["AssumeRolePolicyDocument"], indent=2))

print("\n=== INLINE POLICIES ===")
names = iam.list_role_policies(RoleName=IAM_ROLE)["PolicyNames"]
for n in names:
    p = iam.get_role_policy(RoleName=IAM_ROLE, PolicyName=n)
    print(f"--- {n} ---")
    print(json.dumps(p["PolicyDocument"], indent=2))

print("\n=== ATTACHED MANAGED POLICIES ===")
att = iam.list_attached_role_policies(RoleName=IAM_ROLE)["AttachedPolicies"]
print([a["PolicyName"] for a in att] or "none")
