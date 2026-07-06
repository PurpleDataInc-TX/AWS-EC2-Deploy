#!/usr/bin/env python3
"""
deploy_aws_ec2.py
Creates an AWS EC2 instance equivalent to the Azure cloudpi-deploy-azure-vm setup.

Azure → AWS:
  VM + Managed Identity  → EC2 + IAM Instance Profile
  Azure Key Vault        → AWS Secrets Manager
  NSG (80/443)           → Security Group
  Azure Public IP        → Elastic IP

Prerequisites:
  pip install boto3
  aws configure  (or set AWS_* env vars / use an instance role)

Usage:
  python deploy_aws_ec2.py
  REGION=us-west-2 INSTANCE_TYPE=t3.xlarge python deploy_aws_ec2.py
"""

import json
import os
import sys
import time
import textwrap

import boto3
from botocore.exceptions import ClientError


# ─── Configuration ────────────────────────────────────────────────────────────
REGION               = os.getenv("REGION",               "us-east-1")
INSTANCE_TYPE        = os.getenv("INSTANCE_TYPE",        "t3.large")   # 2 vCPU / 8 GB
ROOT_VOLUME_SIZE     = int(os.getenv("ROOT_VOLUME_SIZE", "30"))        # GB - OS only
DATA_VOLUME_SIZE     = int(os.getenv("DATA_VOLUME_SIZE", "64"))        # GB - Docker + app data, mounted at /data
KEY_PAIR_NAME        = os.getenv("KEY_PAIR_NAME",        "cloudpi-key")
TAG_NAME             = os.getenv("TAG_NAME",             "cloudpi-vm")
SECRET_NAME          = os.getenv("SECRET_NAME",          "cloudpi-secrets")
ROLE_NAME            = os.getenv("ROLE_NAME",            "cloudpi-ec2-role")
INSTANCE_PROFILE     = os.getenv("INSTANCE_PROFILE",     "cloudpi-ec2-profile")
POLICY_NAME          = os.getenv("POLICY_NAME",          "CloudPiSecretsPolicy")
SG_NAME              = os.getenv("SG_NAME",              "cloudpi-sg")
AMI_ID               = os.getenv("AMI_ID",               "")           # auto-resolved if blank

# "Automation & Recommendations" checkbox in deploy_interactive.sh. When on, the
# instance role also gets the write/remediation actions from
# terraform/automation/cloudpi-aws-automation.tf (start/stop/modify/terminate
# EC2 & RDS, autoscaling update). Enabled when TF_SCRIPT selects the automation
# variant, or AUTOMATION is truthy.
AUTOMATION = (
    os.getenv("TF_SCRIPT", "").strip() == "cloudpi-aws-automation.tf"
    or os.getenv("AUTOMATION", "").strip().lower() in ("1", "true", "yes", "on")
)


# ─── Helpers ──────────────────────────────────────────────────────────────────
def info(msg):    print(f"[INFO]  {msg}")
def ok(msg):      print(f"[OK]    {msg}")
def warn(msg):    print(f"[WARN]  {msg}")
def die(msg):     sys.exit(f"[ERROR] {msg}")


def get_clients():
    session = boto3.Session(region_name=REGION)
    return {
        "ec2":  session.client("ec2"),
        "iam":  session.client("iam"),
        "sts":  session.client("sts"),
    }


# ─── 1. Resolve latest Ubuntu 22.04 LTS AMI ───────────────────────────────────
def resolve_ami(ec2) -> str:
    if AMI_ID:
        return AMI_ID
    info(f"Resolving latest Ubuntu 22.04 LTS AMI in {REGION}...")
    resp = ec2.describe_images(
        Owners=["099720109477"],
        Filters=[
            {"Name": "name",                  "Values": ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]},
            {"Name": "state",                 "Values": ["available"]},
            {"Name": "architecture",          "Values": ["x86_64"]},
            {"Name": "virtualization-type",   "Values": ["hvm"]},
        ],
    )
    images = sorted(resp["Images"], key=lambda i: i["CreationDate"], reverse=True)
    if not images:
        die("Could not resolve Ubuntu 22.04 AMI.")
    ami = images[0]["ImageId"]
    ok(f"AMI resolved: {ami}")
    return ami


# ─── 2. IAM Role + Instance Profile (≈ Azure Managed Identity) ────────────────
def ensure_iam_role(iam, sts) -> str:
    trust = json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "ec2.amazonaws.com"},
            "Action": "sts:AssumeRole",
        }],
    })

    info(f"Ensuring IAM role '{ROLE_NAME}'...")
    try:
        iam.get_role(RoleName=ROLE_NAME)
        warn(f"IAM role '{ROLE_NAME}' already exists — skipping creation.")
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchEntity":
            raise
        iam.create_role(
            RoleName=ROLE_NAME,
            AssumeRolePolicyDocument=trust,
            Description="CloudPi EC2 role - read/write AWS Secrets Manager (equiv. Azure Key Vault)",
        )
        ok("IAM role created.")

    account_id = sts.get_caller_identity()["Account"]

    # Equivalent to:
    #   Azure "Key Vault Secrets User"    → GetSecretValue
    #   Azure "Key Vault Secrets Officer" → CreateSecret + PutSecretValue + UpdateSecret
    policy_statements = [
            {
                "Sid": "ReadSecrets",
                "Effect": "Allow",
                "Action": [
                    "secretsmanager:GetSecretValue",
                    "secretsmanager:DescribeSecret",
                    "secretsmanager:ListSecretVersionIds",
                ],
                "Resource": f"arn:aws:secretsmanager:{REGION}:{account_id}:secret:{SECRET_NAME}*",
            },
            {
                "Sid": "WriteSecrets",
                "Effect": "Allow",
                "Action": [
                    "secretsmanager:CreateSecret",
                    "secretsmanager:PutSecretValue",
                    "secretsmanager:UpdateSecret",
                    "secretsmanager:TagResource",
                ],
                "Resource": f"arn:aws:secretsmanager:{REGION}:{account_id}:secret:{SECRET_NAME}*",
            },
            {
                "Sid": "BillingRead",
                "Effect": "Allow",
                "Action": [
                    # ce/cur restricted to the exact actions CloudPi uses (matches live IAM policy)
                    "ce:GetCostAndUsage",
                    "ce:GetCostAndUsageWithResources",
                    "ce:GetCostForecast",
                    "ce:GetDimensionValues",
                    "ce:GetTags",
                    "cur:DescribeReportDefinitions",
                ],
                "Resource": "*",
            },
            {
                "Sid": "OrgRead",
                "Effect": "Allow",
                "Action": [
                    "organizations:Describe*",
                    "organizations:List*",
                    "account:ListRegions",
                    "account:GetRegionOptStatus",
                ],
                "Resource": "*",
            },
            {
                "Sid": "InventoryRead",
                "Effect": "Allow",
                "Action": [
                    "ec2:DescribeKeyPairs",
                    "ec2:Describe*",
                    "rds:Describe*",
                    "elasticache:Describe*",
                    "lambda:List*",
                    "lambda:Get*",
                    "cloudwatch:GetMetricData",
                    "cloudwatch:ListMetrics",
                    "cloudwatch:Describe*",
                    "logs:Describe*",
                    "tag:GetResources",
                    "resourcegroupstaggingapi:GetResources",
                ],
                "Resource": "*",
            },
            {
                "Sid": "CurS3Read",
                "Effect": "Allow",
                "Action": [
                    "s3:GetObject",
                    "s3:ListBucket",
                ],
                "Resource": "*",
            },
    ]

    # "Automation & Recommendations" checkbox → add the write/remediation
    # statement from terraform/automation/cloudpi-aws-automation.tf. Kept in sync
    # with that file's AutomationRemediation Sid.
    if AUTOMATION:
        info("Automation & Recommendations enabled — adding remediation (write) permissions.")
        policy_statements.append({
            "Sid": "AutomationRemediation",
            "Effect": "Allow",
            "Action": [
                "ec2:StartInstances",
                "ec2:StopInstances",
                "ec2:ModifyInstanceAttribute",
                "ec2:TerminateInstances",
                "ec2:DeleteVolume",
                "ec2:DeleteSnapshot",
                "ec2:ReleaseAddress",
                "ec2:CreateTags",
                "ec2:DeleteTags",
                "rds:StartDBInstance",
                "rds:StopDBInstance",
                "rds:ModifyDBInstance",
                "autoscaling:UpdateAutoScalingGroup",
            ],
            "Resource": "*",
        })

    secrets_policy = json.dumps({
        "Version": "2012-10-17",
        "Statement": policy_statements,
    })

    iam.put_role_policy(
        RoleName=ROLE_NAME,
        PolicyName=POLICY_NAME,
        PolicyDocument=secrets_policy,
    )
    _variant = "read-only + automation/remediation" if AUTOMATION else "read-only"
    ok(f"IAM inline policy '{POLICY_NAME}' attached ({_variant}).")

    info(f"Ensuring instance profile '{INSTANCE_PROFILE}'...")
    try:
        iam.get_instance_profile(InstanceProfileName=INSTANCE_PROFILE)
        warn(f"Instance profile '{INSTANCE_PROFILE}' already exists — skipping.")
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchEntity":
            raise
        iam.create_instance_profile(InstanceProfileName=INSTANCE_PROFILE)
        iam.add_role_to_instance_profile(
            InstanceProfileName=INSTANCE_PROFILE,
            RoleName=ROLE_NAME,
        )
        ok("Instance profile created and role attached.")
        info("Waiting 10 s for IAM propagation...")
        time.sleep(10)

    return INSTANCE_PROFILE


# ─── 3. Security Group (≈ Azure NSG: allow 80 + 443 inbound) ──────────────────
def ensure_security_group(ec2) -> str:
    info(f"Ensuring security group '{SG_NAME}'...")

    vpc_resp = ec2.describe_vpcs(Filters=[{"Name": "isDefault", "Values": ["true"]}])
    vpcs = vpc_resp.get("Vpcs", [])
    if not vpcs:
        die("No default VPC found. Set VPC_ID env var and update this script.")
    vpc_id = vpcs[0]["VpcId"]

    existing = ec2.describe_security_groups(
        Filters=[
            {"Name": "group-name", "Values": [SG_NAME]},
            {"Name": "vpc-id",     "Values": [vpc_id]},
        ]
    )["SecurityGroups"]

    if existing:
        sg_id = existing[0]["GroupId"]
        warn(f"Security group '{SG_NAME}' already exists ({sg_id}) — reusing.")
        return sg_id

    sg = ec2.create_security_group(
        GroupName=SG_NAME,
        Description="CloudPi: allow HTTP (80) and HTTPS (443) inbound",
        VpcId=vpc_id,
    )
    sg_id = sg["GroupId"]

    rules = [
        {"IpProtocol": "tcp", "FromPort": 80,  "ToPort": 80,  "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "HTTP - Lets Encrypt ACME"}]},
        {"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443, "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "HTTPS - application traffic"}]},
        {"IpProtocol": "tcp", "FromPort": 22,  "ToPort": 22,  "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "SSH - restrict to your IP in production"}]},
    ]
    ec2.authorize_security_group_ingress(GroupId=sg_id, IpPermissions=rules)
    ok(f"Security group created: {sg_id}")
    return sg_id


# ─── 4. User Data (bootstraps the EC2 instance on first boot) ─────────────────
def build_user_data() -> str:
    return textwrap.dedent("""\
        #!/bin/bash
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y
        apt-get upgrade -y

        # Create service user (mirrors 'azureadmin' on Azure)
        if ! id "cloudpiadmin" &>/dev/null; then
          useradd -m -s /bin/bash cloudpiadmin
          usermod -aG sudo cloudpiadmin
        fi
        echo "cloudpiadmin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cloudpiadmin
        chmod 440 /etc/sudoers.d/cloudpiadmin

        # ── Data volume: format + mount the second EBS volume at /data ──────────
        # Everything that grows over time (Docker images/containers/volumes, the
        # CloudPi app checkout) lives here instead of the root volume, so root
        # never fills up. Attached as /dev/sdf; shows up as /dev/nvme1n1 on
        # Nitro instances (t3/t3a/m5/c5/...) or /dev/xvdf on Xen instances.
        DATA_DEV=""
        for i in $(seq 1 30); do
          for d in /dev/nvme1n1 /dev/xvdf /dev/sdf; do
            if [ -b "$d" ]; then DATA_DEV="$d"; break 2; fi
          done
          sleep 2
        done

        if [ -z "$DATA_DEV" ]; then
          echo "WARNING: data volume device not found after 60s - continuing with root volume only" >&2
        else
          if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
            mkfs.ext4 -F "$DATA_DEV"
          fi
          mkdir -p /data
          DATA_UUID=$(blkid -s UUID -o value "$DATA_DEV")
          grep -q "$DATA_UUID" /etc/fstab || echo "UUID=$DATA_UUID /data ext4 defaults,nofail 0 2" >> /etc/fstab
          mount /data
        fi

        # Docker's data-root (images/containers/volumes) → /data, set up BEFORE
        # docker-ce is installed so the daemon starts with this config from boot 1.
        mkdir -p /data/docker /etc/docker
        cat > /etc/docker/daemon.json <<'DOCKERCFG'
        {
          "data-root": "/data/docker"
        }
        DOCKERCFG

        # Docker Engine + Compose plugin
        apt-get install -y ca-certificates curl gnupg lsb-release
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \\
          | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \\
          https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \\
          > /etc/apt/sources.list.d/docker.list
        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        usermod -aG docker cloudpiadmin
        systemctl enable --now docker

        # Certbot (Let's Encrypt)
        apt-get install -y certbot

        # AWS CLI v2
        apt-get install -y unzip
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
        unzip -q /tmp/awscliv2.zip -d /tmp
        /tmp/aws/install
        rm -rf /tmp/awscliv2.zip /tmp/aws

        # jq + git
        apt-get install -y jq git python3-pip python3-boto3

        # App directory lives on the data volume; /home/cloudpiadmin/cloudpi is a
        # symlink to it so the existing deploy_interactive*.sh scripts work unchanged.
        if [ -d /data ] && [ ! -e /home/cloudpiadmin/cloudpi ]; then
          mkdir -p /data/cloudpi
          chown cloudpiadmin:cloudpiadmin /data/cloudpi
          ln -s /data/cloudpi /home/cloudpiadmin/cloudpi
        fi

        # NOTE: application files are NOT cloned here. deploy_interactive.sh step
        # 10b populates /home/cloudpiadmin/cloudpi (git clone for a fresh install,
        # rsync for a local bundle, or migration). Cloning here as well produced a
        # UNION of the GitHub repo and the uploaded bundle on the instance
        # (duplicate/mismatched .env, Azure keyvault scripts, stray .py/.sh), so
        # the clone was removed to keep the app dir deterministic.

        # Enable SSH for cloudpiadmin using the same EC2 key pair
        mkdir -p /home/cloudpiadmin/.ssh
        cp /home/ubuntu/.ssh/authorized_keys /home/cloudpiadmin/.ssh/authorized_keys
        chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/.ssh
        chmod 700 /home/cloudpiadmin/.ssh
        chmod 600 /home/cloudpiadmin/.ssh/authorized_keys

        # tmpfs for secrets (equiv. Azure /run/secrets-tmp)
        mkdir -p /run/secrets-tmp
        mount -t tmpfs -o size=2m,mode=0700 tmpfs /run/secrets-tmp
        echo 'tmpfs /run/secrets-tmp tmpfs size=2m,mode=0700 0 0' >> /etc/fstab

        touch /var/log/cloudpi-bootstrap-done
        echo "CloudPi bootstrap complete at $(date)" >> /var/log/cloudpi-bootstrap.log
    """)


# ─── 5. Launch EC2 Instance ────────────────────────────────────────────────────
def prompt_key_pair() -> str:
    """Return the key pair name to use, prompting the user if KEY_PAIR_NAME was not set via env."""
    env_override = os.getenv("KEY_PAIR_NAME")
    if env_override:
        info(f"Using key pair from KEY_PAIR_NAME env var: {env_override}")
        return env_override

    print(f"""
  Key pair options:
    1) Use existing key pair: {KEY_PAIR_NAME}  (default)
    2) Enter a custom key pair name
    3) No key pair (skip SSH key attachment)
""")
    while True:
        print("  Choice [1]: ", end="", flush=True)
        choice = input().strip() or "1"
        if choice == "1":
            return KEY_PAIR_NAME
        elif choice == "2":
            print("  Custom key pair name: ", end="", flush=True)
            name = input().strip()
            if name:
                return name
            warn("No name entered — falling back to default.")
            return KEY_PAIR_NAME
        elif choice == "3":
            return "none"
        else:
            warn("Invalid choice — please enter 1, 2, or 3.")


def ensure_key_pair(ec2, key_pair_name: str) -> str:
    """Verify the key pair exists in AWS; offer to import or create it if not."""
    if key_pair_name.lower() == "none":
        return key_pair_name

    try:
        ec2.describe_key_pairs(KeyNames=[key_pair_name])
        ok(f"Key pair '{key_pair_name}' found in AWS.")
        return key_pair_name
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code == "UnauthorizedOperation":
            warn(f"Cannot verify key pair — IAM user lacks ec2:DescribeKeyPairs. Proceeding.")
            warn("Add ec2:DescribeKeyPairs to the IAM user/role policy to enable this check.")
            return key_pair_name
        if code != "InvalidKeyPair.NotFound":
            raise

    warn(f"Key pair '{key_pair_name}' does not exist in AWS ({REGION}).")
    print(f"""
  Options:
    1) Import existing .pem file  (keeps your current private key)
    2) Create a new key pair in AWS  (saves new .pem to ~/.ssh/)
    3) Abort
""")
    while True:
        print("  Choice [1]: ", end="", flush=True)
        choice = input().strip() or "1"

        if choice == "1":
            default_pem = os.path.expanduser(f"~/.ssh/{key_pair_name}.pem")
            print(f"  Path to .pem file [{default_pem}]: ", end="", flush=True)
            pem_path = input().strip() or default_pem
            pem_path = os.path.expanduser(pem_path)
            if not os.path.exists(pem_path):
                warn(f"File not found: {pem_path}")
                continue
            import subprocess
            result = subprocess.run(
                ["ssh-keygen", "-y", "-f", pem_path],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                warn(f"Could not extract public key: {result.stderr.strip()}")
                continue
            pub_key = result.stdout.strip().encode()
            ec2.import_key_pair(KeyName=key_pair_name, PublicKeyMaterial=pub_key)
            ok(f"Key pair '{key_pair_name}' imported into AWS from {pem_path}.")
            return key_pair_name

        elif choice == "2":
            resp = ec2.create_key_pair(KeyName=key_pair_name)
            out_path = os.path.expanduser(f"~/.ssh/{key_pair_name}.pem")
            with open(out_path, "w") as f:
                f.write(resp["KeyMaterial"])
            os.chmod(out_path, 0o400)
            ok(f"New key pair created. Private key saved to {out_path}")
            return key_pair_name

        elif choice == "3":
            die("Aborted by user.")

        else:
            warn("Invalid choice — please enter 1, 2, or 3.")


def launch_instance(ec2, ami_id: str, sg_id: str, profile_name: str, key_pair_name: str) -> str:
    info(f"Launching EC2 instance ({INSTANCE_TYPE}, AMI: {ami_id})...")

    launch_kwargs = {
        "ImageId":           ami_id,
        "InstanceType":      INSTANCE_TYPE,
        "MinCount":          1,
        "MaxCount":          1,
        "SecurityGroupIds":  [sg_id],
        "UserData":          build_user_data(),
        "IamInstanceProfile": {"Name": profile_name},
        "BlockDeviceMappings": [
            {
                "DeviceName": "/dev/sda1",   # root - OS only
                "Ebs": {"VolumeSize": ROOT_VOLUME_SIZE, "VolumeType": "gp3", "DeleteOnTermination": True},
            },
            {
                "DeviceName": "/dev/sdf",    # data - Docker + CloudPi app, mounted at /data
                "Ebs": {"VolumeSize": DATA_VOLUME_SIZE, "VolumeType": "gp3", "DeleteOnTermination": True},
            },
        ],
        "MetadataOptions": {
            "HttpTokens":   "required",   # IMDSv2 enforced
            "HttpEndpoint": "enabled",
        },
        "TagSpecifications": [{
            "ResourceType": "instance",
            "Tags": [
                {"Key": "Name",    "Value": TAG_NAME},
                {"Key": "Project", "Value": "CloudPi"},
            ],
        }],
    }

    if key_pair_name.lower() != "none":
        launch_kwargs["KeyName"] = key_pair_name

    resp = ec2.run_instances(**launch_kwargs)
    instance_id = resp["Instances"][0]["InstanceId"]
    ok(f"Instance launched: {instance_id}")
    return instance_id


# ─── 6. Allocate Elastic IP and associate with instance ───────────────────────
def allocate_and_associate_eip(ec2, instance_id: str) -> str:
    info("Waiting for instance to reach 'running' state...")
    waiter = ec2.get_waiter("instance_running")
    waiter.wait(InstanceIds=[instance_id])

    info("Allocating Elastic IP (AWS assigns the address)...")
    # Reuse an unassociated EIP if the account limit is reached
    try:
        alloc = ec2.allocate_address(Domain="vpc")
    except ClientError as e:
        if "AddressLimitExceeded" not in str(e):
            raise
        warn("EIP limit reached — checking for unassociated Elastic IPs to reuse...")
        existing = ec2.describe_addresses(Filters=[{"Name": "domain", "Values": ["vpc"]}])
        free = [a for a in existing["Addresses"] if "AssociationId" not in a]
        if not free:
            die("EIP limit reached and no unassociated Elastic IPs available. "
                "Release an EIP in the AWS console or request a limit increase.")
        alloc = free[0]
        ok(f"Reusing unassociated Elastic IP: {alloc['PublicIp']}  (Allocation ID: {alloc['AllocationId']})")
    alloc_id  = alloc["AllocationId"]
    public_ip = alloc["PublicIp"]
    ok(f"Elastic IP: {public_ip}  (Allocation ID: {alloc_id})")

    ec2.associate_address(InstanceId=instance_id, AllocationId=alloc_id)
    ok(f"Elastic IP {public_ip} associated with instance {instance_id}")
    ok("This IP is permanent — it persists through reboots and stop/start.")
    return public_ip


# ─── Main ─────────────────────────────────────────────────────────────────────
def main():
    clients = get_clients()
    ec2, iam, sts = clients["ec2"], clients["iam"], clients["sts"]

    key_pair    = prompt_key_pair()
    ami_id      = resolve_ami(ec2)
    profile     = ensure_iam_role(iam, sts)
    sg_id       = ensure_security_group(ec2)
    key_pair    = ensure_key_pair(ec2, key_pair)
    instance_id = launch_instance(ec2, ami_id, sg_id, profile, key_pair)
    public_ip   = allocate_and_associate_eip(ec2, instance_id)

    separator = "═" * 59
    print(f"""
{separator}
  CloudPi EC2 Deployment Complete
{separator}
  Instance ID    : {instance_id}
  Public IP      : {public_ip}
  Instance Type  : {INSTANCE_TYPE}
  Root Volume    : {ROOT_VOLUME_SIZE} GB  (OS only)
  Data Volume    : {DATA_VOLUME_SIZE} GB  (mounted at /data - Docker + CloudPi app)
  Region         : {REGION}
  IAM Role       : {ROLE_NAME}
  Secret Name    : {SECRET_NAME}  (AWS Secrets Manager)
  Security Group : {sg_id}

  Next steps:
  1. SSH:      ssh -i ~/.ssh/{key_pair}.pem cloudpiadmin@{public_ip}
  2. Secrets:  python setup_aws_secrets.py upload
  3. Services: python setup_docker_compose_service.py
  4. TLS cert: sudo certbot certonly --standalone -d your.domain.com
{separator}
""")


if __name__ == "__main__":
    main()
