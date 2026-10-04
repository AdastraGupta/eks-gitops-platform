# ─── AWS RDS PostgreSQL (Multi-AZ) ─────────────────────────────────────────────
# Provisions a production-grade, fully managed PostgreSQL database on AWS RDS.
# Multi-AZ keeps a synchronous standby replica in a second Availability Zone.
# AWS automatically fails over to the standby if the primary becomes unavailable.
# ────────────────────────────────────────────────────────────────────────────────

# ── DB Subnet Group ───────────────────────────────────────────────────────────
# Tells RDS which private subnets to place the primary and standby instances in.
# Using private subnets ensures the database is never directly reachable from
# the internet — only from resources inside the VPC (i.e., EKS worker nodes).
resource "aws_db_subnet_group" "rds" {
  name        = "${var.cluster_name}-rds-subnet-group"
  description = "Subnet group for ${var.cluster_name} RDS PostgreSQL instance"
  subnet_ids  = module.vpc.private_subnets

  tags = {
    Name        = "${var.cluster_name}-rds-subnet-group"
    Environment = var.environment
  }
}

# ── RDS Security Group ────────────────────────────────────────────────────────
# Restricts inbound PostgreSQL traffic (port 5432) exclusively to the EKS
# worker node security group. No public access is permitted.
resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds-sg"
  description = "Allow PostgreSQL access from EKS worker nodes only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from EKS worker nodes and VPC pods"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
    cidr_blocks     = [module.vpc.vpc_cidr_block]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.cluster_name}-rds-sg"
    Environment = var.environment
  }
}

# ── RDS PostgreSQL Instance ───────────────────────────────────────────────────
# Creates a managed PostgreSQL 15 instance with Multi-AZ enabled.
# AWS manages automated backups, OS patching, and failover automatically.
resource "aws_db_instance" "postgres" {
  identifier = "${var.cluster_name}-postgres"

  # ── Engine ──────────────────────────────────────────────────────────────────
  engine         = "postgres"
  engine_version = "15"

  # ── Instance Size & Storage ──────────────────────────────────────────────────
  instance_class        = var.rds_instance_class
  allocated_storage     = 20
  max_allocated_storage = 100 # Enable autoscaling up to 100 GiB
  storage_type          = "gp3"
  storage_encrypted     = true # Encrypt data at rest

  # ── Database Credentials ─────────────────────────────────────────────────────
  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  # ── High Availability ────────────────────────────────────────────────────────
  # Multi-AZ provisions a synchronous standby in a different AZ.
  # Automatic failover occurs within 60-120 seconds if the primary fails.
  multi_az = var.rds_multi_az

  # ── Networking ───────────────────────────────────────────────────────────────
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false # Only accessible from inside the VPC

  # ── Backup & Maintenance ─────────────────────────────────────────────────────
  backup_retention_period = var.environment == "prod" ? 7 : 1 # 7 days for prod, 1 day for dev/staging
  backup_window           = "03:00-04:00"                     # UTC — low-traffic window
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # deletion_protection: Prevents terraform destroy from deleting the RDS instance.
  # Enabled automatically for production — must be manually disabled before `terraform destroy`.
  deletion_protection = var.environment == "prod"

  # ── Lifecycle ────────────────────────────────────────────────────────────────
  # skip_final_snapshot = false in prod: Creates a final DB snapshot on destruction.
  # In dev/staging, skipped for convenience (no persistent data worth preserving).
  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${var.cluster_name}-postgres-final-snapshot" : null

  tags = {
    Name        = "${var.cluster_name}-postgres"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
