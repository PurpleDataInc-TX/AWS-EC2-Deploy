# CloudPi AWS integration — Terraform

Two self-contained variants. The `Automation & Recommendations` checkbox in
`deploy_interactive.sh` sets `TF_SCRIPT`, which selects the variant:

| Checkbox | TF_SCRIPT | Folder | IAM permissions |
|----------|-----------|--------|-----------------|
| No  (default) | `main.tf`                    | `readonly/`   | read-only (billing / inventory / CUR S3) |
| Yes           | `cloudpi-aws-automation.tf`  | `automation/` | read-only **+** automation/remediation (write) |

## Why two folders (not two files in one folder)
Both variants define the same IAM role/user, so Terraform cannot have both in a
single directory (duplicate resources). Each folder is a standalone root module.

## Apply
```bash
cd terraform/readonly        # or terraform/automation
terraform init
terraform apply \
  -var trusted_account_id=<CLOUDPI_ACCOUNT_ID> \
  -var external_id=<EXTERNAL_ID> \
  -var 'cur_bucket_arns=["arn:aws:s3:::<your-cur-bucket>"]'
```

## Notes
- `readonly/main.tf` restricts `ce`/`cur` to the exact actions CloudPi uses
  (matches the live IAM policy) instead of `ce:*` / `cur:*`.
- `automation/cloudpi-aws-automation.tf` adds a write `AutomationRemediation`
  statement. **Confirm that action list against CloudPi's automation spec /
  console-generated policy before applying to production.**
