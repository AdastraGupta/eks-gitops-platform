# ─── General ───────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region where all resources will be created."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name for the EKS cluster and associated AWS resources."
  type        = string
  default     = "taskmanager-cluster"
}

variable "environment" {
  description = "Deployment environment tag (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

# ─── VPC ───────────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AWS Availability Zones to deploy subnets into."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (EKS nodes run here)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (ALB/NLB load balancers live here)."
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

# ─── EKS Cluster ───────────────────────────────────────────────────────────────

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.30"
}

# ─── Node Group 1: System / Infrastructure (ON_DEMAND) ───────────────────────
# Runs: Ingress-nginx, ArgoCD, Prometheus, Grafana, EFK, Jaeger, K8sGPT
# Uses ON_DEMAND for 100% availability of core platform services.

variable "system_node_instance_type" {
  description = "EC2 instance type for the system node group. Needs ≥ 4GB RAM for Elasticsearch + Prometheus."
  type        = string
  default     = "t3.medium" # 2 vCPU, 4 GB RAM
}

variable "system_node_capacity_type" {
  description = "Capacity type for system nodes: ON_DEMAND (high reliability) or SPOT."
  type        = string
  default     = "ON_DEMAND"
}

variable "system_node_min_size" {
  description = "Minimum number of nodes in the system node group."
  type        = number
  default     = 1
}

variable "system_node_max_size" {
  description = "Maximum number of nodes in the system node group."
  type        = number
  default     = 3
}

variable "system_node_desired_size" {
  description = "Desired (initial) number of nodes in the system node group."
  type        = number
  default     = 2
}

# ─── Node Group 2: Application Workloads (SPOT) ───────────────────────────────
# Runs: frontend (Nginx) and backend (PostgREST) pods only.
# Uses SPOT for ~70% EC2 cost savings — safe because pods are stateless.

variable "app_node_instance_type" {
  description = "EC2 instance type for the application node group. t3.small is sufficient for stateless frontend/backend pods."
  type        = string
  default     = "t3.small" # 2 vCPU, 2 GB RAM
}

variable "app_node_capacity_type" {
  description = "Capacity type for app nodes: SPOT (cost-optimised) or ON_DEMAND."
  type        = string
  default     = "SPOT"
}

variable "app_node_min_size" {
  description = "Minimum number of nodes in the application node group."
  type        = number
  default     = 1
}

variable "app_node_max_size" {
  description = "Maximum number of nodes in the application node group."
  type        = number
  default     = 4
}

variable "app_node_desired_size" {
  description = "Desired (initial) number of nodes in the application node group."
  type        = number
  default     = 2
}

# ─── EFK Logging Stack ─────────────────────────────────────────────────────────

variable "efk_enabled" {
  description = "Enable the EFK (Elasticsearch, Fluent Bit, Kibana) logging stack."
  type        = bool
  default     = true
}

variable "efk_elasticsearch_volume_size" {
  description = "Size of the EBS gp3 PersistentVolume for Elasticsearch data (in Gi)."
  type        = number
  default     = 10
}

# ─── RDS PostgreSQL ────────────────────────────────────────────────────────────

variable "rds_instance_class" {
  description = "DB instance class for AWS RDS PostgreSQL."
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_multi_az" {
  description = "Enable Multi-AZ deployment for RDS PostgreSQL (false for cost savings)."
  type        = bool
  default     = false # Cost optimized: Single-AZ (saves 50% on RDS)
}

variable "db_name" {
  description = "Name of the initial database to create in RDS."
  type        = string
  default     = "taskdb"
}

variable "db_username" {
  description = "Master username for the RDS PostgreSQL database."
  type        = string
  default     = "postgres"
}

variable "db_password" {
  description = "Master password for the RDS PostgreSQL database."
  type        = string
  sensitive   = true
  default     = "postgres123"
}

# ─── Prometheus + Grafana Monitoring Stack ────────────────────────────────────

variable "monitoring_enabled" {
  description = "Enable the Prometheus + Grafana monitoring stack via Helm (kube-prometheus-stack)."
  type        = bool
  default     = true
}

variable "monitoring_prometheus_volume_size" {
  description = "Size of the EBS gp3 PersistentVolume for Prometheus metrics storage (in Gi)."
  type        = number
  default     = 10
}

variable "teams_webhook_url" {
  description = "Microsoft Teams incoming webhook URL for Alertmanager and CI/CD alerts."
  type        = string
  sensitive   = true
  default     = ""
}

# ─── ArgoCD GitOps Controller ─────────────────────────────────────────────────

variable "argocd_enabled" {
  description = "Enable ArgoCD GitOps controller via Helm (argo/argo-cd chart). Set false to skip during initial bootstrap."
  type        = bool
  default     = true
}

# ─── Jaeger Distributed Tracing ───────────────────────────────────────────────

variable "tracing_enabled" {
  description = "Enable Jaeger distributed tracing stack via Helm (jaegertracing/jaeger chart)."
  type        = bool
  default     = true
}

# ─── K8sGPT — AI-Powered SRE Operator ────────────────────────────────────────

variable "k8sgpt_enabled" {
  description = "Enable K8sGPT Operator for AI-powered Kubernetes incident triage via AWS Bedrock."
  type        = bool
  default     = true
}

variable "k8sgpt_bedrock_model" {
  description = "AWS Bedrock model ID for K8sGPT to use. Claude 3 Haiku is fast and cost-effective."
  type        = string
  default     = "anthropic.claude-3-haiku-20240307-v1:0"
  # Alternative (deeper analysis, higher cost): "anthropic.claude-3-5-sonnet-20240620-v1:0"
}

variable "k8sgpt_anonymize" {
  description = "Anonymize sensitive Kubernetes data (IPs, names, env values) before sending to Bedrock LLM."
  type        = bool
  default     = true
}

# ─── Karpenter: Node Autoscaler ───────────────────────────────────────────────

variable "karpenter_enabled" {
  description = "Enable Karpenter just-in-time EC2 node autoscaler. Provisions right-sized Spot/On-Demand nodes in < 45s when pods are Pending."
  type        = bool
  default     = true
}

# ─── KEDA: Event-Driven Pod Autoscaler ───────────────────────────────────────

variable "keda_enabled" {
  description = "Enable KEDA event-driven pod autoscaling. Also installs Kubernetes Metrics Server required for HPA CPU/Memory triggers."
  type        = bool
  default     = true
}

# ─── SSL / DNS (ACM + Route 53) ────────────────────────────────────────────────

variable "domain_name" {
  description = "Root domain name (e.g. yourdomain.com). Used to create Route 53 Hosted Zone."
  type        = string
  default     = "yourdomain.com"
}

variable "app_subdomain" {
  description = "Subdomain for the public Task Manager app (e.g. tasks -> tasks.yourdomain.com)."
  type        = string
  default     = "tasks"
}

variable "ssl_enabled" {
  description = "Enable HTTPS via ACM certificate + Route 53 DNS alias record on the public NLB."
  type        = bool
  default     = true
}

