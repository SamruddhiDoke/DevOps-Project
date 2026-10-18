output "aws_account_id" {
  description = "AWS account ID the infrastructure was created in"
  value       = data.aws_caller_identity.current.account_id
}

output "vpc_id" {
  description = "The ID of the custom VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "The CIDR block associated with the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "List of IDs for the 2 public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of IDs for the 2 private subnets"
  value       = aws_subnet.private[*].id
}

output "internet_gateway_id" {
  description = "The ID of the Internet Gateway"
  value       = aws_internet_gateway.igw.id
}

output "nat_gateway_ip" {
  description = "The public Elastic IP attached to the NAT Gateway"
  value       = aws_eip.nat.public_ip
}

output "backend_ecr_repository_url" {
  description = "ECR repository URL for backend"
  value       = aws_ecr_repository.backend.repository_url
}

output "frontend_ecr_repository_url" {
  description = "ECR repository URL for frontend"
  value       = aws_ecr_repository.frontend.repository_url
}

output "eks_cluster_security_group_id" {
  description = "Additional security group attached to the EKS control plane"
  value       = aws_security_group.eks_cluster.id
}

output "eks_managed_cluster_security_group_id" {
  description = "EKS-created cluster security group used by nodes/pods (trusted by RDS)"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "aws_lbc_role_arn" {
  description = "IAM role for the AWS Load Balancer Controller service account (IRSA)"
  value       = aws_iam_role.lbc.arn
}

output "rds_endpoint" {
  description = "RDS MySQL hostname (private)"
  value       = aws_db_instance.mysql.address
}

output "jenkins_instance_id" {
  value = var.create_jenkins ? aws_instance.jenkins[0].id : null
}

output "jenkins_public_ip" {
  description = "Use in ansible/inventory.ini (Ansible configures the Jenkins host)"
  value       = var.create_jenkins ? aws_instance.jenkins[0].public_ip : null
}

output "jenkins_url" {
  value = var.create_jenkins ? "http://${aws_instance.jenkins[0].public_ip}:8080" : null
}

output "ci_reports_bucket" {
  description = "S3 bucket receiving per-build CI reports (set as CI_REPORTS_BUCKET in Jenkins)"
  value       = aws_s3_bucket.ci_reports.bucket
}

output "alerts_sns_topic_arn" {
  description = "SNS topic receiving CloudWatch alarm notifications"
  value       = aws_sns_topic.alerts.arn
}

output "db_secret_arn" {
  description = "Secrets Manager secret holding the RDS master credentials (read by scripts/create-db-secret.sh)"
  value       = aws_secretsmanager_secret.db_master.arn
}

output "alerts_audit_queue_url" {
  description = "SQS queue receiving a copy of every alert (verification/audit)"
  value       = var.create_alert_audit_queue ? aws_sqs_queue.alerts_audit[0].url : null
}
