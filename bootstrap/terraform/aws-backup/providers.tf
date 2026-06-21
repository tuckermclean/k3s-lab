# AWS credentials are NOT set here or in any tfvars file.
# They come from secrets.sops.yaml, decrypted at runtime by tf.sh:
#   AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are exported into the environment
#   before terraform runs so the AWS provider picks them up automatically.
#
# The provisioning user (set in secrets.sops.yaml) needs enough IAM permissions
# to create/manage the backup bucket and the longhorn-backup IAM user + policy.
# A convenient scope: AmazonS3FullAccess + IAMFullAccess (or a scoped inline policy
# on just the target bucket and the longhorn-backup user ARN).
#
# Prefer 'make init-aws-backup / plan-aws-backup / apply-aws-backup' from the repo
# root, which handle age key recovery and SOPS decryption automatically.
provider "aws" {
  region = var.region
}
