variable "aws_region" {
  description = "AWS region for deploying infrastructure"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Name prefix for all infrastructure resources"
  type        = string
  default     = "order-inventory"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the custom VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability Zones to use in the chosen region"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the 2 public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "database_subnet_cidrs" {
  description = "CIDR blocks for the 2 private database subnets (RDS only; no internet route)"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the 2 private subnets"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

# -----------------------------------------------------------------------------
# EKS
# -----------------------------------------------------------------------------
variable "eks_version" {
  description = "Kubernetes version. Use a version in AWS STANDARD support: clusters on extended-support versions cost 6x more per hour (check: aws eks describe-cluster-versions)."
  type        = string
  default     = "1.36"
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint (kubectl). Defaults to admin_cidr_blocks when empty; must not be empty overall."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.eks_public_access_cidrs, "0.0.0.0/0")
    error_message = "Do not open the EKS API to 0.0.0.0/0."
  }
}

variable "node_instance_types" {
  description = "Instance types for the EKS managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 3
}

# -----------------------------------------------------------------------------
# RDS MySQL
# -----------------------------------------------------------------------------
variable "db_engine_version" {
  description = "RDS MySQL major/minor version. 8.0 is in RDS extended support (extra charges); 8.4 is the current LTS."
  type        = string
  default     = "8.4"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_username" {
  description = "RDS master username"
  type        = string
  default     = "admin"
}

variable "db_backup_retention_days" {
  description = "RDS automated backup retention (days, 1-35). Enables point-in-time recovery."
  type        = number
  default     = 7
}

# -----------------------------------------------------------------------------
# Jenkins
# -----------------------------------------------------------------------------
variable "create_jenkins" {
  description = "Create the Jenkins EC2 server. Set false for the low-cost learning profile (run Jenkins locally from ci/jenkins)."
  type        = bool
  default     = true
}

variable "admin_cidr_blocks" {
  description = "CIDR blocks allowed to reach Jenkins (SSH 22 and UI 8080). Use your own public IP, e.g. [\"203.0.113.10/32\"]. GitHub webhooks additionally need GitHub's hook ranges or a polling trigger. Required when create_jenkins = true."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.admin_cidr_blocks, "0.0.0.0/0") && (!var.create_jenkins || length(var.admin_cidr_blocks) > 0)
    error_message = "admin_cidr_blocks must list specific CIDRs (0.0.0.0/0 is not allowed) and is required when create_jenkins = true."
  }
}

variable "jenkins_instance_type" {
  description = "EC2 instance type for Jenkins"
  type        = string
  default     = "t3.medium"
}

variable "jenkins_key_name" {
  description = "Existing EC2 key pair name for SSH access to Jenkins"
  type        = string
  default     = "UniversalKey"
}

# -----------------------------------------------------------------------------
# Monitoring
# -----------------------------------------------------------------------------
variable "monthly_budget_usd" {
  description = "AWS Budgets monthly cost limit; alerts at 80% actual and 100% forecast spend go to alert_email."
  type        = number
  default     = 100
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for AWS-side log groups created by this configuration"
  type        = number
  default     = 14
}

variable "create_alert_audit_queue" {
  description = "Subscribe an SQS queue to the alert topic so notification delivery can be verified (and audited) without email"
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Email address subscribed to the SNS alarm topic (confirmation email must be accepted). Leave empty to skip the subscription."
  type        = string
  default     = ""
}
