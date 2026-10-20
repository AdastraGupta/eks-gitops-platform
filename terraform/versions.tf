terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  # S3 backend for remote state storage (required for CI/CD).
  # Bucket, key, region, and DynamoDB table are provided via -backend-config
  # flags in the GitHub Actions workflow for environment-specific state isolation.
  backend "s3" {
    # Partial configuration — these values are injected at runtime:
    #   -backend-config="bucket=<TF_STATE_BUCKET>"
    #   -backend-config="key=k8s-task-manager/<env>/terraform.tfstate"
    #   -backend-config="region=us-east-1"
    #   -backend-config="encrypt=true"
    #   -backend-config="dynamodb_table=<TF_STATE_LOCK_TABLE>"
  }
}
