# =========================================================
# Customer-managed KMS key (~$1/month) used for:
#   - EKS envelope encryption of Kubernetes Secrets (e.g. the database credentials)
#   - SNS alert topic encryption (CloudWatch must be allowed to use the key, which the
#     AWS-managed aws/sns key does not permit, so alarm delivery would silently fail)
# =========================================================

data "aws_iam_policy_document" "app_kms" {
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchAlarmsPublishToEncryptedSns"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "app" {
  description             = "${var.project_name}: EKS secrets and SNS alert encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.app_kms.json

  tags = {
    Name = "${var.project_name}-app-kms"
  }
}

resource "aws_kms_alias" "app" {
  name          = "alias/${var.project_name}-app"
  target_key_id = aws_kms_key.app.key_id
}

# The EKS cluster role needs to use the key for envelope encryption of Secrets
resource "aws_iam_role_policy" "eks_cluster_kms" {
  name = "${var.project_name}-eks-secrets-kms"
  role = aws_iam_role.eks_cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey", "kms:CreateGrant"]
      Resource = aws_kms_key.app.arn
    }]
  })
}
