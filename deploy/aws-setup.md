# AWS Setup — Rising Constellation

This document covers the first-time AWS provisioning needed to deploy
Rising Constellation. It assumes:

- AWS account ready
- Region: **us-east-1**
- Postgres co-located on the EC2 instance (single box)
- HTTP-only for the first deploy (no TLS — that's a follow-up)

The end state is one EC2 instance, one security group, one IAM role
attached to the instance, one Secrets Manager secret, and one SSH key pair.
No RDS, no S3, no Route 53 for this first pass.

## What gets created

| Resource              | Name (suggested)              | Why                                                  |
| --------------------- | ----------------------------- | ---------------------------------------------------- |
| EC2 key pair          | `rc-prod`                     | SSH access to the instance from your dev box         |
| Security group        | `rc-prod-sg`                  | Allows :22 (you only), :80 (world)                   |
| IAM role (instance)   | `rc-prod-instance-role`       | Grants the EC2 instance permission to read the secret |
| IAM instance profile  | `rc-prod-instance-profile`    | Wrapper that attaches the role to the instance       |
| Secrets Manager secret| `rc/prod/env`                 | JSON blob of all env vars consumed by runtime.exs    |
| EC2 instance          | `rc-prod-1`                   | The box that runs the release                        |

## IAM user (for me to drive provisioning)

Create an IAM user with **programmatic access** (access key + secret).
Attach this inline policy — it's the minimum scope needed to drive the
provisioning steps below:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Provisioning",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:DescribeInstances",
        "ec2:DescribeImages",
        "ec2:DescribeKeyPairs",
        "ec2:CreateKeyPair",
        "ec2:DeleteKeyPair",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:DescribeSecurityGroups",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:AssociateIamInstanceProfile",
        "ec2:DescribeIamInstanceProfileAssociations",
        "ec2:CreateTags",
        "ec2:DescribeTags",
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:DescribeAvailabilityZones"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IamRoleForInstance",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:PassRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile"
      ],
      "Resource": [
        "arn:aws:iam::*:role/rc-prod-*",
        "arn:aws:iam::*:instance-profile/rc-prod-*"
      ]
    },
    {
      "Sid": "SecretsForApp",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:CreateSecret",
        "secretsmanager:DeleteSecret",
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:UpdateSecret",
        "secretsmanager:TagResource"
      ],
      "Resource": "arn:aws:secretsmanager:*:*:secret:rc/prod/*"
    }
  ]
}
```

Issue the access key, then share with me:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- (optionally) the path to the EC2 key pair PEM if you create it via the
  console; otherwise I'll create it via CLI and we'll save the private key
  output to `~/.ssh/rc-prod.pem`

## Instance role policy (attached to `rc-prod-instance-role`)

This is what the EC2 instance itself uses to fetch the secret at boot. It's
NOT the IAM user — it's a separate role attached to the instance via the
instance profile.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:us-east-1:*:secret:rc/prod/env-*"
    }
  ]
}
```

Trust policy (who can assume the role — only EC2):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

## Secrets Manager secret format

The secret named `rc/prod/env` is a JSON object. Keys/values mirror
[.env.example](../.env.example). Example shape (with placeholder values —
generate real ones with `mix phx.gen.secret`):

```json
{
  "RC_HOST": "ec2-1-2-3-4.compute-1.amazonaws.com",
  "SECRET_KEY_BASE": "<64 chars from `mix phx.gen.secret`>",
  "GUARDIAN_SECRET_KEY": "<64 chars from `mix phx.gen.secret`>",
  "DATABASE_URL": "ecto://rcprod:<generated-pw>@127.0.0.1:5432/rc_prod",
  "RELEASE_NODE": "rc@127.0.0.1",
  "RELEASE_COOKIE": "<32-byte hex from `openssl rand -hex 32`>",
  "MAILER_API_KEY": "<mailjet api key, or placeholder for testing>",
  "MAILER_SECRET": "<mailjet secret, or placeholder>",
  "S3_BUCKET": "placeholder-no-uploads-yet",
  "S3_ASSET_HOST": "https://placeholder.example/",
  "AWS_ACCESS_KEY_ID": "AKIAxxx-or-placeholder",
  "AWS_SECRET_ACCESS_KEY": "<key or placeholder>",
  "RC_SCHEME": "http",
  "RC_URL_PORT": "80",
  "DATABASE_SSL": "false",
  "APPSIGNAL_ACTIVE": "false"
}
```

`RELEASE_NODE` and `RELEASE_COOKIE` are required by the OTP release scripts.
`rc@127.0.0.1` is correct for single-node; for multi-node clustering use the
instance's private IP so other nodes can reach it.

The S3 + mailer entries are required by runtime.exs but only used at
request-time. For a first-deploy smoke test, placeholder values are fine —
the release will boot and serve, just can't send emails or accept uploads.

## Provisioning steps (will execute when you hand me the IAM creds)

The exact `aws ec2 ...` calls aren't in this doc — I'll run them
interactively so you can see each one. Rough sequence:

1. `aws ec2 create-key-pair` → save private key to `~/.ssh/rc-prod.pem`
2. `aws ec2 create-security-group` + two `authorize-security-group-ingress`
   calls (ssh from your IP, http from the world)
3. `aws iam create-role` + `put-role-policy` + `create-instance-profile`
   + `add-role-to-instance-profile`
4. `aws secretsmanager create-secret` with the JSON above
5. `aws ec2 run-instances`:
   - AMI: latest Ubuntu 22.04 LTS in us-east-1
   - Instance type: `t3.small` (2 vCPU, 2 GiB) — fine for a smoke test, can
     resize later
   - Key pair: `rc-prod`
   - Security group: `rc-prod-sg`
   - IAM instance profile: `rc-prod-instance-profile`
   - 30 GiB gp3 root volume (Postgres lives on it for this first pass)
6. SCP `deploy/` to the instance, then SSH in and run:
   ```sh
   sudo RC_HOST=<public-dns> RC_SECRET_ID=rc/prod/env AWS_REGION=us-east-1 \
     bash bootstrap-host.sh
   ```
7. From the repo root locally:
   ```sh
   VUE_APP_BASE_URL=http://<public-dns> make build deploy
   ```
8. Smoke-test in a browser at `http://<public-dns>/`.

## After the first deploy works

- Move the secret values you'd never check into git (real Mailjet keys,
  Stripe keys, etc.) into the Secrets Manager secret. Re-run
  `systemctl start rc-fetch-secrets && systemctl restart rc` to pick them up.
- Register a real domain, point an A record at the EIP, run certbot, swap
  the nginx config for the TLS-enabled version from
  `deploy/nginx/rc.conf.example`.
- Move to RDS Postgres when you want HA / a separate DB scale axis.
- Set up CloudWatch log shipping or wire APPSIGNAL_PUSH_API_KEY.

## Teardown

For the smoke test, "teardown" is just:
- `aws ec2 terminate-instances --instance-ids <id>`
- `aws secretsmanager delete-secret --secret-id rc/prod/env --force-delete-without-recovery`
- `aws iam remove-role-from-instance-profile` + `delete-instance-profile` + `delete-role-policy` + `delete-role`
- `aws ec2 delete-security-group --group-name rc-prod-sg`
- `aws ec2 delete-key-pair --key-name rc-prod`

I can script that as `deploy/bin/teardown.sh` once the first deploy is
green.
