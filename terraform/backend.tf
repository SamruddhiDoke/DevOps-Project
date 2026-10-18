# Remote state: encrypted, versioned S3 bucket created by terraform/bootstrap, with S3-native
# state locking (Terraform >= 1.10). The bucket name is not secret.
terraform {
  backend "s3" {
    bucket       = "order-inventory-tfstate-038215676861"
    key          = "order-inventory/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
