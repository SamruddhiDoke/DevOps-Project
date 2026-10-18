terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State is local by default. For team use, migrate it to S3 with locking:
  # see backend.tf.example and the README "Terraform state" section.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  eks_public_access_cidrs = length(var.eks_public_access_cidrs) > 0 ? var.eks_public_access_cidrs : var.admin_cidr_blocks
  cluster_name            = "${var.project_name}-eks"
  app_namespace           = "order-inventory"
}

# -----------------------------------------------------------------------------
# 1. Virtual Private Cloud (VPC)
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-${var.environment}-vpc"
  }
}

# -----------------------------------------------------------------------------
# 2. Internet Gateway (IGW) for Public Subnets
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.environment}-igw"
  }
}

# -----------------------------------------------------------------------------
# 3. Public Subnets (Across 2 Availability Zones)
#    kubernetes.io/role/elb lets the AWS Load Balancer Controller place
#    internet-facing ALBs here (subnet auto-discovery).
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  # Nothing should get a public IP implicitly (Jenkins requests one explicitly)
  map_public_ip_on_launch = false

  tags = {
    Name                     = "${var.project_name}-${var.environment}-public-subnet-${count.index + 1}"
    Type                     = "Public"
    "kubernetes.io/role/elb" = "1"
  }
}

# -----------------------------------------------------------------------------
# 4. Private Subnets (Across 2 Availability Zones)
# -----------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name                              = "${var.project_name}-${var.environment}-private-subnet-${count.index + 1}"
    Type                              = "Private"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# -----------------------------------------------------------------------------
# 5. Elastic IP (EIP) for NAT Gateway
# -----------------------------------------------------------------------------
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-${var.environment}-nat-eip"
  }
}

# -----------------------------------------------------------------------------
# 6. NAT Gateway (single, in Public Subnet 1, to keep cost down; not AZ-redundant)
# -----------------------------------------------------------------------------
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.project_name}-${var.environment}-nat-gw"
  }

  depends_on = [aws_internet_gateway.igw]
}

# -----------------------------------------------------------------------------
# 7. Public Route Table & Associations
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# 8. Private Route Table & Associations
# -----------------------------------------------------------------------------
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnet_cidrs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# =========================================================
# ECR REPOSITORIES
# Immutable tags: every build pushes a unique <build>-<commit> tag, so a tag
# always identifies exactly one image and rollbacks are reproducible.
# =========================================================

resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}-backend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-backend"
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project_name}-frontend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-frontend"
  }
}

# Keep storage cost bounded while retaining enough history for rollbacks
resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = { backend = aws_ecr_repository.backend.name, frontend = aws_ecr_repository.frontend.name }
  repository = each.value

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 20 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

# =========================================================
# EKS SECURITY GROUP (additional SG for the control-plane ENIs)
# =========================================================

resource "aws_security_group" "eks_cluster" {
  name        = "${var.project_name}-eks-cluster-sg"
  description = "Security group for EKS cluster"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-eks-cluster-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "eks_cluster_all_egress" {
  security_group_id = aws_security_group.eks_cluster.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# =========================================================
# EKS IAM ROLE
# =========================================================

resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "eks.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-eks-cluster-role"
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# =========================================================
# EKS CLUSTER
# =========================================================

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_version

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids = [
      aws_subnet.private[0].id,
      aws_subnet.private[1].id
    ]

    security_group_ids = [
      aws_security_group.eks_cluster.id
    ]

    # Nodes and Jenkins (inside the VPC) use the private endpoint; the public endpoint
    # is only reachable from the admin CIDRs (kubectl from your workstation).
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = local.eks_public_access_cidrs
  }

  # Envelope-encrypt Kubernetes Secrets (database credentials) with the project KMS key
  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.app.arn
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.eks_public_access_cidrs) > 0
      error_message = "Set eks_public_access_cidrs or admin_cidr_blocks so the EKS API is not open to the internet."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy.eks_cluster_kms
  ]

  tags = {
    Name = local.cluster_name
  }
}

# =========================================================
# EKS WORKER NODE IAM ROLE
# =========================================================

resource "aws_iam_role" "eks_nodes" {
  name = "${var.project_name}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-eks-node-role"
  }
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_ecr_read_only" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# =========================================================
# EKS MANAGED NODE GROUP
# Nodes (and therefore pods) use the EKS-managed cluster security group,
# which is what the RDS ingress rule below trusts.
# =========================================================

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn

  subnet_ids = [
    aws_subnet.private[0].id,
    aws_subnet.private[1].id
  ]

  instance_types = var.node_instance_types

  capacity_type = "ON_DEMAND"

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_read_only
  ]

  tags = {
    Name = "${var.project_name}-node-group"
  }
}

# =========================================================
# OIDC PROVIDER (IAM Roles for Service Accounts)
# =========================================================

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer

  client_id_list = [
    "sts.amazonaws.com"
  ]

  thumbprint_list = [
    data.tls_certificate.eks.certificates[0].sha1_fingerprint
  ]

  tags = {
    Name = "${var.project_name}-eks-oidc"
  }
}

locals {
  oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# =========================================================
# EBS CSI DRIVER IAM ROLE
# =========================================================

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRoleWithWebIdentity"
    ]

    principals {
      type = "Federated"

      identifiers = [
        aws_iam_openid_connect_provider.eks.arn
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"

      values = [
        "system:serviceaccount:kube-system:ebs-csi-controller-sa"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name = "${var.project_name}-ebs-csi-role"

  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json

  tags = {
    Name = "${var.project_name}-ebs-csi-role"
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# =========================================================
# AWS LOAD BALANCER CONTROLLER IAM ROLE (IRSA)
# Replaces the previously hand-created role whose trust policy hard-coded the
# OIDC id of a deleted cluster. The permissions document is the upstream
# controller policy kept in k8s/iam_policy.json.
# =========================================================

data "aws_iam_policy_document" "lbc_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "lbc" {
  name   = "${var.project_name}-aws-lbc-policy"
  policy = file("${path.module}/../k8s/iam_policy.json")
}

resource "aws_iam_role" "lbc" {
  name               = "${var.project_name}-aws-lbc-role"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume_role.json

  tags = {
    Name = "${var.project_name}-aws-lbc-role"
  }
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

# =========================================================
# EKS ADD-ONS
# =========================================================

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # The controller pods need nodes to become ACTIVE
  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi,
    aws_eks_node_group.main
  ]
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.main
  ]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.main
  ]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.main
  ]
}

# =========================================================
# RDS MySQL (private subnets, reachable only from EKS pods)
# =========================================================

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Security group for RDS MySQL"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

# Managed node groups attach the EKS-created cluster security group to every node,
# so this is the source pods connect from.
resource "aws_vpc_security_group_ingress_rule" "rds_mysql" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "MySQL from EKS nodes/pods"
}

# Dedicated database subnets: no route to the internet (local VPC traffic only)
resource "aws_subnet" "database" {
  count             = length(var.database_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.database_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.project_name}-${var.environment}-database-subnet-${count.index + 1}"
    Type = "Database"
  }
}

resource "aws_route_table" "database" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.environment}-database-rt"
  }
}

resource "aws_route_table_association" "database" {
  count          = length(var.database_subnet_cidrs)
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}

# Master password generated here (never typed, committed or reused) and stored in Secrets
# Manager, from which scripts/create-db-secret.sh reads it. It is also kept in the encrypted
# remote state, which is why the state bucket is private, encrypted and TLS-only.
resource "random_password" "db_master" {
  length           = 32
  special          = true
  override_special = "!#%^*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_master" {
  name                    = "${var.project_name}/rds-master"
  description             = "RDS MySQL master credentials for the order-inventory application"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id = aws_secretsmanager_secret.db_master.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_master.result
    host     = aws_db_instance.mysql.address
    port     = aws_db_instance.mysql.port
    dbname   = aws_db_instance.mysql.db_name
  })
}

resource "aws_db_subnet_group" "mysql" {
  name = "${var.project_name}-mysql-subnet-group"

  subnet_ids = aws_subnet.database[*].id

  tags = {
    Name = "${var.project_name}-mysql-subnet-group"
  }
}

# Enforce TLS for every client connection (the backend connects with sslMode=REQUIRED)
resource "aws_db_parameter_group" "mysql" {
  name_prefix = "${var.project_name}-mysql84-"
  family      = "mysql8.4"
  description = "order-inventory MySQL settings"

  parameter {
    name  = "require_secure_transport"
    value = "1"
  }

  # Slow-query log (exported to CloudWatch Logs below) for diagnosing latency
  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2"
  }

  # Size MySQL for the 1 GiB db.t3.micro: the 8.4 defaults (buffer pool ~75 % of RAM plus
  # performance_schema) left ~50 MB free and caused swapping (found via the FreeableMemory alarm).
  parameter {
    name  = "innodb_buffer_pool_size"
    value = "{DBInstanceClassMemory*3/8}"
  }

  parameter {
    name         = "performance_schema"
    value        = "0"
    apply_method = "pending-reboot"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "mysql" {
  identifier = "${var.project_name}-mysql"

  engine         = "mysql"
  engine_version = var.db_engine_version

  instance_class        = var.db_instance_class
  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "order_inventory_db"
  username = var.db_username
  password = random_password.db_master.result

  db_subnet_group_name   = aws_db_subnet_group.mysql.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible  = false
  parameter_group_name = aws_db_parameter_group.mysql.name

  # Daily automated backups + point-in-time recovery (storage up to the DB size is free)
  backup_retention_period    = var.db_backup_retention_days
  backup_window              = "19:00-19:30" # UTC (00:30-01:00 IST)
  maintenance_window         = "sun:20:00-sun:21:00"
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true

  # Error and slow-query logs in CloudWatch Logs (small volume; retention set in monitoring.tf)
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  # Lab settings: allow a clean `terraform destroy`. For production set
  # deletion_protection = true and skip_final_snapshot = false.
  skip_final_snapshot = true
  deletion_protection = false

  depends_on = [aws_cloudwatch_log_group.rds]

  tags = {
    Name = "${var.project_name}-mysql"
  }
}

