# Full portfolio deployment: EKS (2 nodes) + RDS + Jenkins EC2 + monitoring.
#   terraform plan -var-file=environments/full.tfvars
# Secrets are NOT set here: export TF_VAR_db_password and (optionally) TF_VAR_alert_email.
# Replace the documentation CIDR below with your own public IP (curl https://checkip.amazonaws.com).
admin_cidr_blocks  = ["203.0.113.10/32"]
create_jenkins     = true
node_desired_size  = 2
node_min_size      = 1
node_max_size      = 3
monthly_budget_usd = 300
