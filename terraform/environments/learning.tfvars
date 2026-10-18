# Low-cost learning profile: one worker node, no Jenkins EC2 (run Jenkins locally from ci/jenkins),
# 1-day backups. Still includes EKS, RDS, NAT and the ALB, which dominate cost — destroy after use.
#   terraform plan -var-file=environments/learning.tfvars
# Replace the documentation CIDR below with your own public IP (curl https://checkip.amazonaws.com).
admin_cidr_blocks        = ["203.0.113.10/32"]
create_jenkins           = false
node_desired_size        = 1
node_min_size            = 1
node_max_size            = 2
db_backup_retention_days = 1
monthly_budget_usd       = 100
