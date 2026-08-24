# Provision the S3 uploads bucket for Forge thumbnails (and any future
# Waffle uploads), plus the instance-role permissions to write it.
#
# Needs an ADMIN AWS profile: the claude-access user can neither create
# buckets nor touch IAM (verified 2026-08-24), so this is the one manual
# step in the uploads-to-S3 move. Everything else (app config, env flip,
# file sync, nginx proxy block) is already in place or scripted.
#
#   ./deploy/provision-uploads-bucket.ps1 -AwsProfile my-admin
#
# Idempotent: re-running overwrites the policies with identical content;
# create-bucket on an existing owned bucket errors harmlessly.
#
# Design notes:
# - Object Ownership stays the modern default (bucket owner enforced,
#   ACLs disabled); the app writes with the bucket-owner-full-control
#   canned ACL, the only one such buckets accept.
# - Public reads come from a bucket policy scoped to the uploads/*
#   prefix, which is why BlockPublicPolicy must be false. ACL-based
#   public access stays fully blocked.
# - The role policy is inline on rc-prod-instance-role and scoped to
#   this bucket only.

param(
    [Parameter(Mandatory = $true)]
    [string]$AwsProfile,
    [string]$Bucket = "rc-prod-uploads-553872001542",
    [string]$Region = "us-east-1",
    [string]$RoleName = "rc-prod-instance-role"
)

$ErrorActionPreference = "Stop"

Write-Host "[1/4] creating bucket $Bucket"
aws --profile $AwsProfile s3api create-bucket --bucket $Bucket --region $Region

Write-Host "[2/4] public access block (policy-based public read allowed, ACLs blocked)"
aws --profile $AwsProfile s3api put-public-access-block --bucket $Bucket `
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false"

Write-Host "[3/4] bucket policy: public GetObject on uploads/*"
$bucketPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadUploads",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::$Bucket/uploads/*"
    }
  ]
}
"@
$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $bucketPolicy -Encoding ascii
aws --profile $AwsProfile s3api put-bucket-policy --bucket $Bucket --policy ("file://" + $tmp.FullName)
Remove-Item $tmp

Write-Host "[4/4] instance-role policy: read/write this bucket"
$rolePolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "UploadsBucketRW",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::$Bucket/*"
    },
    {
      "Sid": "UploadsBucketList",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::$Bucket"
    }
  ]
}
"@
$tmp2 = New-TemporaryFile
Set-Content -Path $tmp2 -Value $rolePolicy -Encoding ascii
aws --profile $AwsProfile iam put-role-policy --role-name $RoleName --policy-name "rc-uploads-bucket" --policy-document ("file://" + $tmp2.FullName)
Remove-Item $tmp2

Write-Host ""
Write-Host "Done. Remaining steps (Claude can run these over ssh):"
Write-Host "  1. /etc/rc/env: UPLOADS_STORAGE=s3, S3_BUCKET=$Bucket, remove placeholder AWS_* keys"
Write-Host "  2. sync existing thumbnails: aws s3 cp --recursive /home/rc/storage/thumbnails s3://$Bucket/uploads/thumbnails --cache-control 'public, max-age=900' --content-type image/png"
Write-Host "  3. nginx: enable the /uploads/ proxy location (deploy/nginx/rc.conf.example)"
Write-Host "  4. deploy the branch (or runtime-flip via rpc) so the app writes to S3"
