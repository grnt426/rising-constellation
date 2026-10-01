# AWS Setup — Tetrarchy Falls (formerly Rising Constellation)

This document covers the first-time AWS provisioning needed to deploy
Tetrarchy Falls. It assumes:

- AWS account ready
- Region: **us-east-1**
- Postgres co-located on the EC2 instance (single box)
- HTTP-only for the first deploy (no TLS — that's a follow-up)

The end state is one EC2 instance, one security group, one IAM role
attached to the instance, one Secrets Manager secret, and one SSH key pair.
No RDS, no S3, no Route 53 for this first pass.

> **Post-launch additions:** the backup bucket, instance role, and the
> `rc/prod/env` secret are now provisioned by a single idempotent script,
> `deploy/provision-dr.ps1`. Current live identifiers and the full
> rebuild runbook live in `deploy/DISASTER-RECOVERY.md`.

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
        "ec2:DescribeInstanceStatus",
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
      "Sid": "RemoteBuildAmiLookup",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameters"
      ],
      "Resource": "arn:aws:ssm:*::parameter/aws/service/ami-amazon-linux-latest/*"
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
  "S3_BUCKET": "placeholder-no-uploads-yet",
  "S3_ASSET_HOST": "https://placeholder.example/",
  "AWS_ACCESS_KEY_ID": "AKIAxxx-or-placeholder",
  "AWS_SECRET_ACCESS_KEY": "<key or placeholder>",
  "RC_SCHEME": "http",
  "RC_URL_PORT": "80",
  "DATABASE_SSL": "false"
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

- Move the secret values you'd never check into git (Stripe keys, Discord
  token, etc.) into the Secrets Manager secret. Outbound mail needs no
  secrets — SES sends are signed with the instance role. Re-run
  `systemctl start rc-fetch-secrets && systemctl restart rc` to pick them up.
- Register a real domain, point an A record at the EIP, run certbot, swap
  the nginx config for the TLS-enabled version from
  `deploy/nginx/rc.conf.example`.
- Move to RDS Postgres when you want HA / a separate DB scale axis.
- Set up CloudWatch log shipping.

## Teardown

For the smoke test, "teardown" is just:
- `aws ec2 terminate-instances --instance-ids <id>`
- `aws secretsmanager delete-secret --secret-id rc/prod/env --force-delete-without-recovery`
- `aws iam remove-role-from-instance-profile` + `delete-instance-profile` + `delete-role-policy` + `delete-role`
- `aws ec2 delete-security-group --group-name rc-prod-sg`
- `aws ec2 delete-key-pair --key-name rc-prod`

I can script that as `deploy/bin/teardown.sh` once the first deploy is
green.

## Remote build (transient Graviton spot)

Builds the prod release on a fresh AWS Graviton spot instance instead of
locally via QEMU emulation. Cuts a ~35-minute desktop build down to
~2.5 minutes wall-clock (~4 when the dependencies changed) and frees up
your workstation. Tarballs ship
builder→prod directly (intra-region, free transfer); your laptop only
handles verification + CloudFront invalidation.

### What this assumes

- Prod is in `us-east-1` (override with `RC_BUILDER_REGION`).
- The existing `rc-prod` AWS profile + IAM user with the EC2/SSM
  permissions in the JSON above (the diff added `ec2:DescribeInstanceStatus`
  and `ssm:GetParameters` for the AL2023 ARM AMI lookup).
- The existing `rc-prod` EC2 key pair — same one you ssh prod with. The
  private key is uploaded to the builder transiently per build and dies
  with the instance.

### One-time setup

PowerShell:

```powershell
.\deploy\bin\setup-builder.ps1
```

Bash (POSIX):

```sh
./deploy/bin/setup-builder.sh
```

Either creates a security group `rc-builder-sg` allowing SSH from your
current public IP. Idempotent — re-run after your home IP changes to add
the new one (old rules stay; clean up manually if you want the SG tidy).

### Per-build usage

PowerShell (the daily driver on Windows):

```powershell
# Build remotely + deploy to prod
.\deploy\release.ps1 -BuildRemote

# Benchmark a remote build: build remotely, pull tarballs back to .\build\,
# do NOT deploy. Useful before committing to the remote path.
.\deploy\release.ps1 -BuildRemote -BuildOnly

# Backend-only remote deploy of a specific revision
.\deploy\release.ps1 f9e221e -BuildRemote -BackOnly

# Get-Help .\deploy\release.ps1 -Detailed   # full flag reference
```

Bash (POSIX / Git-Bash):

```sh
./deploy/release.sh --remote                  # remote build + deploy
./deploy/release.sh --remote --build-only     # benchmark, no deploy
./deploy/release.sh --remote --back-only f9e221e

./deploy/release.sh --help                    # full flag reference
```

`remote-build.sh` prints a per-phase timings table at the end so you can
see exactly where wall-clock goes — the "docker buildx" line is the
apples-to-apples comparison with your local QEMU build time — followed by
the slowest steps of the docker build. The Dockerfile's stages run in
parallel, so those step times overlap; the build is as long as its longest
chain (Elixir: toolchain → deps → app → release), not their sum.

### What happens on AWS

1. `aws ec2 run-instances` — c7g.xlarge, spot one-time, max price = on-demand
   (falls back to on-demand automatically if no spot capacity). The image is
   Amazon's ECS-optimized AL2023 (AL2023 with Docker preinstalled, no extra
   charge); stock AL2023 is the fallback, with Docker installed at boot.
2. Poll for the public address, then for `docker info` over SSH — up about
   20s after launch (about a minute on the fallback image)
3. Source tar-streamed in via SSH; the builder downloads the dependency
   cache (below) from S3 when there is one for the current `mix.lock`
4. `docker buildx build` natively (no `--platform`), exporting the
   `artifacts` stage (the two tarballs) straight to `build/`
5. `deploy/bin/deploy.sh` runs on the builder — scp to prod + remote install
6. `aws ec2 terminate-instances` (EXIT trap, runs even on failure)

Spot interruption mid-build is the main failure mode and falls back to
re-running on-demand on the operator's side.

### Dependency cache

Compiling the Elixir dependencies is most of an uncached build and only
changes with `mix.lock`, so `remote-build.sh` keeps the fetched + compiled
dependencies of the last build as a ~37MB tarball, in two places:

- **S3**, `s3://rc-build-cache-553872001542` (override with
  `RC_BUILD_CACHE_S3`; empty turns it off). Shared by every machine that
  deploys. It is a bucket of its own — private, nothing else stored in it,
  nothing served from it. Attach `deploy/iam/claude-access-build-cache.json`
  to the deploy user (it covers this one bucket only), then create it once:

  ```powershell
  .\deploy\provision-build-cache.ps1 -AwsProfile rc-prod
  ```

  The builder has no AWS credentials: the script signs a 15-minute download
  link and the builder fetches the object in-region. Objects expire after
  30 days, so a cache in constant use is rebuilt about once a month.
  Storage is ~$0.001/month per tarball; transfers stay inside the region.
- **The operator's machine** (`%LOCALAPPDATA%\rc\build-cache` on Windows,
  `~/.cache/rc/build-cache` elsewhere), used when S3 does not have it or
  cannot be reached, and uploaded with the source. The two most recent are
  kept. If S3 access fails the build only warns and carries on with this
  copy.

How it behaves:

- The key is a hash of `Dockerfile`, `mix.exs` and `mix.lock`. Only an
  exact match is used; any change to one of them is a miss.
- A miss builds everything from scratch, brings the new tarball back and
  stores it in S3 (+5s).
- The tarball holds dependencies only. The application is compiled from the
  streamed source on every build, and the Docker layer cache stays off.
- `--no-deps-cache` / `-NoDepsCache` builds from scratch without touching
  the cache; deleting the directory or the S3 objects is always safe.

### What a build costs

Measured 2026-10-01, cached build of the full release, the builder's whole
life (launch → build → deploy step → terminate). On-demand prices; spot,
the default, has been running at roughly a third of these.

| Builder       | Docker build (cached / uncached) | Builder lifetime | Per deploy (on-demand) |
| ------------- | -------------------------------- | ---------------- | ---------------------- |
| `c7g.xlarge` (default) | ~130s / ~250s           | ~4.5 min         | ~$0.011                |
| `c7g.2xlarge` | ~113s / ~190s                    | ~4.1 min         | ~$0.020                |
| `c7g.4xlarge` | ~75s / ~165s (faster disk, see `remote-build.sh`) | ~3.5 min | ~$0.037 |

The root volume is 40GB gp3, a fraction of a cent for a few minutes.

### Cost / size knobs

| PowerShell                  | Bash                         | Effect                                                  |
| --------------------------- | ---------------------------- | ------------------------------------------------------- |
| `-BuilderType c7g.2xlarge`  | `--builder-type c7g.2xlarge` | Bigger, faster builder: see the table above             |
| `-NoDepsCache`              | `--no-deps-cache`            | Compile every dependency from scratch                   |
| `-OnDemand`                 | `--on-demand`                | Skip the spot attempt (use on-demand)                   |
| `-Keep`                     | `--keep`                     | Don't terminate builder on exit — **costs $$ until you do** |

### Teardown for the builder resources

```sh
aws --profile rc-prod ec2 delete-security-group --group-name rc-builder-sg
```

Instances are transient. The dependency cache is the
`rc-build-cache-553872001542` bucket plus a directory on the operator's
machine (see above); both can be deleted at any time.
