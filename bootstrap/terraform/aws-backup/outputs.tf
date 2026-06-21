output "bucket" {
  description = "S3 bucket name for Longhorn backups."
  value       = aws_s3_bucket.longhorn_backups.bucket
}

output "region" {
  description = "AWS region of the backup bucket."
  value       = var.region
}

output "access_key_id" {
  description = "AWS access key ID for the longhorn-backup IAM user. Copy this into infrastructure/storage/longhorn/backup/secret.sops.yaml via 'make store-longhorn-backup-secret'."
  value       = aws_iam_access_key.longhorn_backup.id
}

output "secret_access_key" {
  description = "AWS secret access key for the longhorn-backup IAM user. Copy this into infrastructure/storage/longhorn/backup/secret.sops.yaml via 'make store-longhorn-backup-secret'."
  value       = aws_iam_access_key.longhorn_backup.secret
  sensitive   = true
}

output "backup_target_url" {
  description = "Value to use for backupTarget in clusters/ovh-lab/longhorn-kustomization.yaml."
  value       = "s3://${aws_s3_bucket.longhorn_backups.bucket}@${var.region}/longhorn"
}
