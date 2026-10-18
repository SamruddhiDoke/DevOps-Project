# =========================================================
# Jenkins CI/CD server (optional: create_jenkins = false for the low-cost learning profile,
# where Jenkins runs locally from ci/jenkins instead).
#
# Terraform creates the instance, network access and IAM permissions only.
# Software (JDK, Maven, Node, Docker, AWS CLI, kubectl, Helm, Trivy, Jenkins) is installed
# and kept up to date by Ansible: ansible/playbooks/jenkins.yml.
# =========================================================

locals {
  jenkins_count = var.create_jenkins ? 1 : 0
}

# ============================================================
# Jenkins Security Group
# ============================================================

resource "aws_security_group" "jenkins" {
  count       = local.jenkins_count
  name        = "order-inventory-jenkins-sg"
  description = "Security group for Jenkins server"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "order-inventory-jenkins-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "jenkins_ssh" {
  for_each          = var.create_jenkins ? toset(var.admin_cidr_blocks) : toset([])
  security_group_id = aws_security_group.jenkins[0].id

  cidr_ipv4   = each.value
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
  description = "SSH from admin networks"
}

resource "aws_vpc_security_group_ingress_rule" "jenkins_web" {
  for_each          = var.create_jenkins ? toset(var.admin_cidr_blocks) : toset([])
  security_group_id = aws_security_group.jenkins[0].id

  cidr_ipv4   = each.value
  from_port   = 8080
  to_port     = 8080
  ip_protocol = "tcp"
  description = "Jenkins UI from admin networks"
}

resource "aws_vpc_security_group_egress_rule" "jenkins_all_egress" {
  count             = local.jenkins_count
  security_group_id = aws_security_group.jenkins[0].id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "eks_api_from_jenkins" {
  count             = local.jenkins_count
  security_group_id = aws_security_group.eks_cluster.id

  referenced_security_group_id = aws_security_group.jenkins[0].id

  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"

  description = "Allow Jenkins to access EKS Kubernetes API"
}

# ============================================================
# Jenkins IAM Role (least privilege: push to the two app repos, upload CI reports,
# describe the cluster; Kubernetes RBAC comes from the access entry below)
# ============================================================

resource "aws_iam_role" "jenkins" {
  count = local.jenkins_count
  name  = "${var.project_name}-jenkins-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.project_name}-jenkins-role"
  }
}

resource "aws_iam_role_policy" "jenkins_ecr_push" {
  count = local.jenkins_count
  name  = "${var.project_name}-jenkins-ecr-push"
  role  = aws_iam_role.jenkins[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "PushPullAppImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = [
          aws_ecr_repository.backend.arn,
          aws_ecr_repository.frontend.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "jenkins_eks_access" {
  count = local.jenkins_count
  name  = "${var.project_name}-jenkins-eks-access"
  role  = aws_iam_role.jenkins[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = aws_eks_cluster.main.arn
    }]
  })
}

resource "aws_iam_role_policy" "jenkins_ci_reports" {
  count = local.jenkins_count
  name  = "${var.project_name}-jenkins-ci-reports"
  role  = aws_iam_role.jenkins[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "${aws_s3_bucket.ci_reports.arn}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "jenkins" {
  count = local.jenkins_count
  name  = "${var.project_name}-jenkins-profile"
  role  = aws_iam_role.jenkins[0].name

  tags = {
    Name = "${var.project_name}-jenkins-profile"
  }
}

# ============================================================
# Latest Ubuntu 24.04 AMI
# ============================================================

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ============================================================
# Jenkins EC2 (configured by Ansible after creation)
# ============================================================

resource "aws_instance" "jenkins" {
  count         = local.jenkins_count
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.jenkins_instance_type

  subnet_id = aws_subnet.public[0].id

  key_name = var.jenkins_key_name

  vpc_security_group_ids = [
    aws_security_group.jenkins[0].id
  ]

  iam_instance_profile = aws_iam_instance_profile.jenkins[0].name

  associate_public_ip_address = true

  # IMDSv2 only (blocks SSRF-style credential theft via IMDSv1). Hop limit 2 lets
  # containers started by Jenkins builds use the instance role.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  # A new AMI release must not silently replace the Jenkins server
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${var.project_name}-jenkins"
    Role = "jenkins"
  }
}

# Jenkins may only edit resources in the application namespace
resource "aws_eks_access_entry" "jenkins" {
  count         = local.jenkins_count
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.jenkins[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins" {
  count         = local.jenkins_count
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.jenkins[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = [local.app_namespace]
  }

  depends_on = [
    aws_eks_access_entry.jenkins
  ]
}
