provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.cluster_name
      ManagedBy   = "Terraform"
      Environment = var.environment
    }
  }
}

# The kubernetes provider is configured after the cluster is created,
# using the EKS cluster endpoint and CA certificate as inputs.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

# The helm provider is configured identically to the kubernetes provider —
# both authenticate to the EKS cluster using the AWS CLI token exchange.
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}
