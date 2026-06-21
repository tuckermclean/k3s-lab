resource "aws_iam_user" "longhorn_backup" {
  name = "longhorn-backup"

  tags = {
    ManagedBy = "terraform"
    Purpose   = "longhorn-backups"
  }
}

resource "aws_iam_access_key" "longhorn_backup" {
  user = aws_iam_user.longhorn_backup.name
}

# Least-privilege policy: Longhorn needs ListBucket + GetBucketLocation to validate
# the backup target, and PutObject + GetObject + DeleteObject to write/read/prune backups.
resource "aws_iam_user_policy" "longhorn_backup" {
  name = "longhorn-backup-s3"
  user = aws_iam_user.longhorn_backup.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.longhorn_backups.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.longhorn_backups.arn}/*"
      }
    ]
  })
}
