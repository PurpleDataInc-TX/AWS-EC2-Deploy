# CloudPi · Post-Deploy First-Use Setup

After `deploy cloudpi on EC2` finishes and you can log in as
`admin@cloudpi.ai`, run through the seven steps below in order. Each step
unlocks the next:

1. **Log in to CloudPi as the default admin** → entry point to all
   subsequent UI steps.
2. **Configure SMTP** → so CloudPi can send invitation / notification mail.
3. **Set up authentication & invite the workspace admin user** — split into
   two sub-steps:
   - **3a (Optional)** Configure **Single Sign-On (OIDC / Azure AD)** so users
     can sign in with their corporate identity. Skip this if you only need
     local username/password accounts.
   - **3b** Invite the workspace admin user. If 3a was completed
     successfully, you can pick **Local User** *or* **Azure AD / Microsoft
     Entra ID (SSO)** for the new user; otherwise only **Local User** is
     available.
4. **Accept the invitation** → activate the new account.
5. **Log in as the new workspace admin** → switch off the default
   `admin@cloudpi.ai` for day-to-day work.
6. **In AWS, create a Data Export (CUR 2.0 / FOCUS 1.0) to S3** → produces
   the billing data CloudPi will read; capture the bucket name and folder
   path.
7. **In CloudPi, wire the S3 bucket into Billing Configuration** → CloudPi
   starts pulling FOCUS-format cost data.

> Prerequisites assumed: deploy succeeded, `https://<HOST_ADDRESS>/` loads,
> and the default `admin@cloudpi.ai / admin123` login returns HTTP 200
> (step 15 of the deploy script).

---

## Step 1 — Log in to CloudPi

Open CloudPi in a browser using the EC2 instance's public or private IP
(whichever the workstation can reach):

```
http://<Public-or-Private-IP>/
```

(or `https://…` if you accepted the self-signed certificate from deploy
step 11 — the browser will warn about the cert; click through.)

Log in with the **default admin credentials configured in `.env`**:

| Field | Value |
|---|---|
| Email | `admin@cloudpi.ai` |
| Password | `admin123` |

> Change this password as soon as practical — deploy step 16 of
> `deploy_interactive_2.sh` resets it via bcrypt straight into the
> database, or you can rotate it from the CloudPi UI under
> **Settings → My Profile → Change Password** once you're signed in.

If the page doesn't load, jump back to deploy step 15 (login verify) and
re-check `sudo docker logs cloudpi-app` on the EC2 box.

---

## Step 2 — Configure SMTP

CloudPi sends user invitations by email, so SMTP must be wired before
inviting anyone.

1. From the left panel, open **Onboarding → SMTP Integration** →
   **SMTP Configuration**.
2. Fill in:
   - **SMTP Host** — e.g. `smtp.office365.com`
   - **SMTP Port** — `587` (STARTTLS) or `465` (TLS-wrapped)
   - **Email Address** — the sender account, e.g. `cloudpi_smtp@cloudpi.ai`
   - **Password** — app password / SMTP credential for that account
3. **Test**. The banner should change to *"Test successful"*. If it
   fails, double-check the settings and repeat this step until the test
   passes.
4. **Save**. The banner first shows *"Successfully saved"*, then settles
   on *"SMTP is already configured. You can view or update the existing
   details."*

**Verify** before leaving the page: trigger any test-email control if the
UI offers one; otherwise jump ahead to Step 3b — a failed invitation in
Step 3b is the practical SMTP smoke test.

---

## Step 3 — Set up authentication & invite the workspace admin user

### 3a — Single Sign-On (OIDC / Azure AD) — **Optional**

Skip this entire sub-step if you only need local username/password
accounts — you can come back later to add SSO.

Configuring SSO unlocks the **Azure AD / Microsoft Entra ID (SSO)** option
in the *User Type* selector of Step 3b. Without 3a, only **Local User** is
available.

1. From the left panel, open **Onboarding → SSO Integration** →
   **Single Sign-On Configuration**.
2. **Basic Configuration**:
   - **Provider Type** — `Azure AD / Microsoft Entra ID` (currently the
     only supported provider).
3. **Provider Settings**:
   - **Issuer URL** — your tenant's OIDC issuer, e.g.
     `https://login.microsoftonline.com/<tenant-id>/v2.0`.
   - **Client ID** — the Application (client) ID from the app registration
     in Azure, e.g. `efc78e5d-6f7f-4fd6-8261-5ebbac91eecd`.
   - **Client Secret** — the corresponding client secret value.
   - **Scopes** — `openid profile email` (the literal string `openid` is
     required; the other two let CloudPi read display name + mailbox).
4. Before saving, on the **Azure portal** side make sure the app
   registration has a **Redirect URI** that matches CloudPi's callback —
   typically `https://<HOST_ADDRESS>/auth/oidc/callback` (check the
   CloudPi UI for the exact URI it expects and paste that into Azure).
5. **Test** the configuration with the *Test* control. A failed test
   means the IdP rejected something — common causes are a wrong issuer
   URL, a missing redirect URI on the Azure side, or scopes that don't
   include `openid`. Fix and retry.
6. Only once the test succeeds, click **Save**. The banner should change
   to *"OIDC provider is already configured. Click edit to update the
   configuration."* (matching the green check in the screenshot.)

> **Important notes** (the same callouts the CloudPi UI shows):
> - Users still have to be **invited** to CloudPi in Step 3b before they
>   can log in via OIDC. SSO authenticates *who* they are; the invite
>   creates the workspace account they're mapped to.
> - The Redirect URI in your IdP settings must match what CloudPi expects.
> - Test before relying on SSO for production sign-ins.

---

### 3b — Invite the workspace admin user

1. From the left panel, open **Onboarding → User Management**, then click
   **+ Invite User**.
2. Fill in:
   - **Email Address** — the user's real mailbox (they'll need to click
     the link from there).
   - **Display Name** — optional but recommended.
   - **User Type**:
     - **Local User** — always available; the user signs in with
       email + password they set in Step 4.
     - **Azure AD / Microsoft Entra ID (SSO)** — **only available if
       Step 3a was completed and tested**. The user signs in via your
       IdP; no password is stored in CloudPi.
   - **Role** — pick the admin role (typically `Workspace Admin`).
3. Click **Send Invitation**.

The user receives an email with an activation link. If the email never
arrives, return to Step 2 and double-check the SMTP credentials and the
outbound port (587/465 must be open from the EC2 security group).

---

## Step 4 — Accept the invitation

The invitee:

1. Opens the email and clicks the **Accept Invitation** link.
2. Lands on CloudPi's "set up your account" page.
3. For a **Local User**: sets a strong password and confirms.
   For **Azure AD SSO**: is redirected to the IdP, signs in there, and
   bounces back already authenticated.
4. Confirmation page shows the account is active.

---

## Step 5 — Log in as the new workspace admin

1. Sign **out** of `admin@cloudpi.ai`.
2. Sign **in** with the new workspace admin user.
3. Confirm the new user can see the workspace and has the admin role
   expected from Step 3b (Users, Settings, Billing should all be visible).

From here on, use this account for day-to-day work and treat
`admin@cloudpi.ai` as a break-glass credential only.

---

## Step 6 — In AWS, create a Data Export to S3 (FOCUS 1.0)

CloudPi reads cost/usage data from an S3 bucket in your AWS account.
You'll create an AWS Billing **Data Export** in FOCUS 1.0 format and
capture four values to paste into CloudPi in Step 7:

- the **S3 bucket name**,
- the **S3 bucket location** (AWS region),
- the **folder path** (S3 prefix) where the export's partitioned files
  land, and
- the **CUR version** (always `FOCUS 1.0` for this flow).

### 6.1 (One-time) Create or pick the destination S3 bucket

If you don't already have one:

1. AWS Console → **S3** → **Create bucket**.
2. **Bucket name**: pick something obvious, e.g.
   `cloudpi-dev-storage-<account-id>` (matches the convention in the
   screenshot: `cloudpi-dev-storage-887514555091`).
3. **Region**: pick a region close to where CloudPi runs — note it down
   (the screenshot uses `us-east-2`). CloudPi will need to know this.
4. Block public access: **leave all enabled** (default).
5. Versioning / encryption: defaults are fine (SSE-S3).
6. Create.

> **Important:** AWS will attach a bucket policy automatically in Step 6.2
> that lets the Billing service write objects in. Don't pre-restrict the
> bucket policy in a way that blocks `billingreports.amazonaws.com`.

### 6.2 Create the FOCUS 1.0 Data Export

1. AWS Console → **Billing and Cost Management** → **Data Exports**
   (left nav under "Cost analysis"). On older accounts this used to be
   called "Cost & Usage Reports" — the FOCUS 1.0 variant is the new UI.
2. Click **Create**.
3. **Export type**: **Standard data export**.
4. **Export name**: e.g. `Myexport0609` (this becomes part of the S3 path).
5. **Data table**:
   - **Table**: `Cost and usage report data`
   - **Format**: **FOCUS 1.0** (this is what the CloudPi UI also expects
     under "CUR Version").
6. **Data table content settings**:
   - **Time granularity**: `Daily` (CloudPi expects daily partitions).
   - **Include all columns**: yes.
7. **Data export delivery options**:
   - **Compression**: `Parquet` is preferred (smaller, faster reads).
   - **File versioning**: `Create new data export file`.
8. **Data export storage settings**:
   - **S3 bucket**: pick the bucket from Step 6.1
     (e.g. `cloudpi-dev-storage-887514555091`).
   - **S3 path prefix**: e.g. `billing_export`. (You can leave this empty
     too — but giving it a prefix keeps the bucket tidy.)
   - AWS will show a sample of the bucket policy it's about to attach —
     click **Save policy to S3 bucket**.
9. **Create export**.

### 6.3 Capture the four values for CloudPi

After the first delivery (usually within 24 hours, but the directory
structure is created immediately so you can preview the path), the
objects land at:

```
s3://<bucket-name>/<prefix>/<export-name>/data/billing_period=YYYY-MM/...
```

Concretely, matching the screenshot:

| CloudPi field | Value to record |
|---|---|
| **S3 Bucket Name** | `cloudpi-dev-storage-887514555091` |
| **S3 Bucket Location** | `us-east-2` |
| **Folder Path** | `billing_export/Myexport0609/data/` |
| **CUR Version** | `FOCUS 1.0` |

> Stop at `data/` — do **not** include the `billing_period=YYYY-MM/`
> partition in the Folder Path. CloudPi discovers each monthly partition
> (`billing_period=2026-06/`, `billing_period=2026-07/`, …) on its own as
> AWS rolls them over.

Write these four values down — you'll paste them into CloudPi in Step 7.

---

## Step 7 — Wire the S3 bucket into CloudPi Billing Configuration

Back in CloudPi (still logged in as the workspace admin from Step 5):

1. From the left panel, open **Admin Settings → AWS / Cloud Integration**
   → **Billing Configuration**.
2. **SELECT FEATURES** — tick **Billing** (the other two,
   *Recommendations* and *Automation*, can stay off for this first pass).
3. Fill **BILLING CONFIGURATION**:
   - **S3 Bucket Name** — paste from Step 6.3
     (e.g. `cloudpi-dev-storage-887514555091`).
   - **S3 Bucket Location** — region from Step 6.1 (e.g. `us-east-2`).
   - **Folder Path** — from Step 6.3
     (e.g. `billing_export/Myexport0609/data/`).
   - **CUR Version** — **FOCUS 1.0** (must match what you picked in Step 6.2).
4. **AWS CREDENTIALS — Master Service Account (MSA)**:
   - If "**N shared credentials available for AWS**" shows in the banner,
     pick an existing MSA from the dropdown.
   - Otherwise click **+ Create New MSA** and provide either:
     - an IAM **access key + secret** with read access to the S3 bucket,
       OR
     - a **cross-account role ARN** that CloudPi can assume.
   - The MSA needs at minimum: `s3:GetObject`, `s3:ListBucket` on
     `arn:aws:s3:::<bucket>` and `arn:aws:s3:::<bucket>/<prefix>/*`.
5. **Save**.

CloudPi will start polling the bucket on its ingestion schedule (daily by
default). The first FOCUS-formatted cost data shows up on the Billing
dashboards once that ingestion run completes.

---

## Verification checklist

After Step 7, confirm:

- [ ] SMTP test email or Step 3b invitation actually arrived.
- [ ] New workspace admin can sign in (Step 5).
- [ ] AWS Data Export shows **Status: Successful** for the most recent
      delivery (AWS Console → Data Exports → your export).
- [ ] S3 bucket has objects under the expected path
      (`aws s3 ls s3://<bucket>/<folder-path> --recursive | head` from
      anywhere with AWS credentials).
- [ ] CloudPi Billing Configuration shows "**Connected**" / no validation
      errors.
- [ ] After CloudPi's first ingestion run, the Billing dashboard shows
      non-zero spend for the current `billing_period`.

If any of these fail, the most common culprits are:

| Symptom | Likely cause |
|---|---|
| No invitation email | SMTP port blocked by EC2 SG (open 587/465 outbound), or wrong app password |
| Data Export status `Failed` | Bucket policy not saved in Step 6.2 — re-run the export creation and accept the policy preview |
| CloudPi says "no data found" | Folder Path goes too deep (includes `billing_period=YYYY-MM/`) — trim back to the export's `.../data/` directory and let CloudPi find the monthly partitions on its own |
| CloudPi says "access denied" | MSA permissions missing — add `s3:ListBucket` on the bucket, not just `s3:GetObject` on objects |
