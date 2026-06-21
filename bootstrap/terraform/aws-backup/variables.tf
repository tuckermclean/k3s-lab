variable "bucket_name" {
  type        = string
  description = "S3 bucket name for Longhorn backups. Must be globally unique across all AWS accounts. Set in terraform.tfvars (gitignored). Commit the same name to clusters/ovh-lab/longhorn-kustomization.yaml once known."
}

variable "region" {
  type        = string
  description = "AWS region for the backup bucket. Match the region in the backupTarget URL and AWS_DEFAULT_REGION in the cluster secret."
  default     = "us-west-2"
}
