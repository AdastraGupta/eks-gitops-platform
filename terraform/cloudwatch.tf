# ─── AWS CloudWatch Observability: Dashboard & Alarms ─────────────────────────
#
# This file provisions:
#   1. CloudWatch Log Group     — Receives Prometheus EMF metrics from the
#                                 CloudWatch Agent DaemonSet (set in eks.tf)
#   2. CloudWatch Dashboard     — Unified 3-widget view of EKS, RDS, and
#                                 PostgREST Prometheus metrics in one pane
#   3. CloudWatch Metric Alarms — RDS high CPU + backend 5xx HTTP error alarms
#
# Metrics flow:
#   App pods (/metrics) → CloudWatch Agent (DaemonSet) → CloudWatch Logs (EMF)
#             → CloudWatch Metrics → Dashboard + Alarms
# ────────────────────────────────────────────────────────────────────────────────

# ── CloudWatch Log Group for Prometheus EMF Metrics ───────────────────────────
# The CloudWatch Agent writes scraped Prometheus metrics as Embedded Metric Format
# (EMF) JSON into this log group. CloudWatch then auto-extracts numeric fields
# into the ContainerInsights/Prometheus metrics namespace — no Lambda needed.
resource "aws_cloudwatch_log_group" "prometheus_emf" {
  name              = "/aws/containerinsights/${var.cluster_name}/prometheus"
  retention_in_days = 7 # Keep 7 days of metric logs to control costs

  tags = {
    Name        = "${var.cluster_name}-prometheus-emf"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── CloudWatch Log Group for Container Insights ───────────────────────────────
# Stores Container Insights performance logs (CPU, memory, disk per pod/node).
resource "aws_cloudwatch_log_group" "container_insights" {
  name              = "/aws/containerinsights/${var.cluster_name}/performance"
  retention_in_days = 7

  tags = {
    Name        = "${var.cluster_name}-container-insights"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── CloudWatch Dashboard ──────────────────────────────────────────────────────
# 4-widget unified dashboard combining:
#   Widget 1 (top-left)  : PostgREST API request rate (Prometheus metric)
#   Widget 2 (top-right) : AWS RDS PostgreSQL CPU Utilization & DB Connections
#   Widget 3 (mid-left)  : EKS Pod CPU usage (Container Insights)
#   Widget 4 (mid-right) : EKS Pod Memory utilization (Container Insights)
resource "aws_cloudwatch_dashboard" "taskmanager" {
  dashboard_name = "${var.cluster_name}-observability"

  dashboard_body = jsonencode({
    widgets = [
      # ── Widget 1: PostgREST Backend API — Request Rate (Prometheus) ───────────
      # Metric source: ContainerInsights/Prometheus
      # Scraped by CloudWatch Agent from backend pods at prometheus.io/scrape: "true"
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 7
        properties = {
          title  = "PostgREST API — HTTP Request Rate (Prometheus)"
          region = var.aws_region
          period = 60
          stat   = "Sum"
          view   = "timeSeries"
          metrics = [
            ["ContainerInsights/Prometheus", "http_requests_total",
              "Namespace", "taskmanager",
              "Service", "backend-svc",
            { "label" : "Total API Requests/min", "color" : "#1f77b4" }],
            ["ContainerInsights/Prometheus", "http_requests_total",
              "Namespace", "taskmanager",
              "Service", "backend-svc",
              "code", "5XX",
            { "label" : "5XX Errors/min", "color" : "#d62728" }]
          ]
          yAxis = {
            left = { min = 0, label = "Requests / min" }
          }
        }
      },

      # ── Widget 2: AWS RDS PostgreSQL — CPU & DB Connections ─────────────────
      # Metric source: AWS/RDS namespace (native CloudWatch, no agent required)
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 7
        properties = {
          title  = "RDS PostgreSQL — CPU & Active DB Connections"
          region = var.aws_region
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "CPUUtilization",
              "DBInstanceIdentifier", aws_db_instance.postgres.identifier,
            { "label" : "CPU %", "stat" : "Average", "color" : "#ff7f0e" }],
            ["AWS/RDS", "DatabaseConnections",
              "DBInstanceIdentifier", aws_db_instance.postgres.identifier,
            { "label" : "Active Connections", "stat" : "Average", "yAxis" : "right", "color" : "#2ca02c" }]
          ]
          yAxis = {
            left  = { min = 0, max = 100, label = "CPU %" }
            right = { min = 0, label = "Connections" }
          }
        }
      },

      # ── Widget 3: EKS Pod CPU Usage — Container Insights ────────────────────
      # Metric source: ContainerInsights namespace (pod-level CPU)
      {
        type   = "metric"
        x      = 0
        y      = 7
        width  = 12
        height = 7
        properties = {
          title  = "EKS Pod CPU Usage — taskmanager Namespace"
          region = var.aws_region
          period = 60
          stat   = "Average"
          view   = "timeSeries"
          metrics = [
            ["ContainerInsights", "pod_cpu_utilization",
              "Namespace", "taskmanager",
              "ClusterName", var.cluster_name,
            { "label" : "Pod CPU %", "color" : "#9467bd" }]
          ]
          yAxis = {
            left = { min = 0, label = "CPU Utilization %" }
          }
        }
      },

      # ── Widget 4: EKS Pod Memory Usage — Container Insights ─────────────────
      # Metric source: ContainerInsights namespace (pod-level memory)
      {
        type   = "metric"
        x      = 12
        y      = 7
        width  = 12
        height = 7
        properties = {
          title  = "EKS Pod Memory Usage — taskmanager Namespace"
          region = var.aws_region
          period = 60
          stat   = "Average"
          view   = "timeSeries"
          metrics = [
            ["ContainerInsights", "pod_memory_utilization",
              "Namespace", "taskmanager",
              "ClusterName", var.cluster_name,
            { "label" : "Pod Memory %", "color" : "#8c564b" }]
          ]
          yAxis = {
            left = { min = 0, max = 100, label = "Memory Utilization %" }
          }
        }
      },

      # ── Widget 5: Istio IngressGateway — Request Rate ────────────────────────
      # Metric source: ContainerInsights/Prometheus — Istio Envoy proxy metrics
      # (Istio exposes metrics at port 15090 /stats/prometheus automatically)
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 12
        height = 7
        properties = {
          title  = "Istio IngressGateway — Request Rate & Success Rate"
          region = var.aws_region
          period = 60
          view   = "timeSeries"
          metrics = [
            ["ContainerInsights/Prometheus", "istio_requests_total",
              "source_workload_namespace", "istio-system",
              "response_code", "200",
            { "label" : "2xx Success/min", "stat" : "Sum", "color" : "#2ca02c" }],
            ["ContainerInsights/Prometheus", "istio_requests_total",
              "source_workload_namespace", "istio-system",
              "response_code", "5XX",
            { "label" : "5xx Errors/min", "stat" : "Sum", "color" : "#d62728" }]
          ]
          yAxis = {
            left = { min = 0, label = "Requests / min" }
          }
        }
      },

      # ── Widget 6: RDS Storage & Free Memory ─────────────────────────────────
      {
        type   = "metric"
        x      = 12
        y      = 14
        width  = 12
        height = 7
        properties = {
          title  = "RDS PostgreSQL — Free Storage & Freeable Memory"
          region = var.aws_region
          period = 300
          stat   = "Average"
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "FreeStorageSpace",
              "DBInstanceIdentifier", aws_db_instance.postgres.identifier,
            { "label" : "Free Storage (bytes)", "color" : "#17becf" }],
            ["AWS/RDS", "FreeableMemory",
              "DBInstanceIdentifier", aws_db_instance.postgres.identifier,
            { "label" : "Freeable Memory (bytes)", "color" : "#bcbd22", "yAxis" : "right" }]
          ]
          yAxis = {
            left  = { min = 0, label = "Free Storage (bytes)" }
            right = { min = 0, label = "Freeable Memory (bytes)" }
          }
        }
      }
    ]
  })
}

# ── CloudWatch Metric Alarm: RDS High CPU ────────────────────────────────────
# Triggers when RDS PostgreSQL CPU exceeds 80% for 2 consecutive 5-minute periods.
# Sustained high CPU on the database is a leading indicator of query saturation
# or under-provisioned instance class.
resource "aws_cloudwatch_metric_alarm" "rds_high_cpu" {
  alarm_name          = "${var.cluster_name}-rds-high-cpu"
  alarm_description   = "RDS PostgreSQL CPU utilization is critically high (>80%). Check for slow queries or scale the DB instance."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2 # Must breach for 2 consecutive periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300 # 5-minute evaluation window
  statistic           = "Average"
  threshold           = 80 # Alert at 80% CPU
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.identifier
  }

  # Alarm state actions — add an SNS topic ARN here to trigger email/Slack/PagerDuty
  # alarm_actions = [aws_sns_topic.alerts.arn]
  # ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name        = "${var.cluster_name}-rds-high-cpu"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── CloudWatch Metric Alarm: RDS Low Free Storage ────────────────────────────
# Triggers when RDS free storage drops below 5 GB — early warning before the
# database runs out of disk space (which causes outages).
resource "aws_cloudwatch_metric_alarm" "rds_low_storage" {
  alarm_name          = "${var.cluster_name}-rds-low-storage"
  alarm_description   = "RDS PostgreSQL free storage is below 5GB. Expand allocated storage or archive old data."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 5368709120 # 5 GB in bytes
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.identifier
  }

  # alarm_actions = [aws_sns_topic.alerts.arn]

  tags = {
    Name        = "${var.cluster_name}-rds-low-storage"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── CloudWatch Metric Alarm: Backend 5xx Errors (Prometheus) ─────────────────
# Triggers when PostgREST backend returns more than 10 HTTP 5xx errors
# within a 5-minute window. Prometheus metric scraped via CloudWatch Agent.
resource "aws_cloudwatch_metric_alarm" "backend_5xx_errors" {
  alarm_name          = "${var.cluster_name}-backend-5xx-errors"
  alarm_description   = "Backend API (PostgREST) is returning elevated 5xx errors. Check PostgREST logs and DB connectivity."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "http_requests_total"
  namespace           = "ContainerInsights/Prometheus"
  period              = 300
  statistic           = "Sum"
  threshold           = 10 # More than 10 errors in 5 minutes
  treat_missing_data  = "notBreaching"

  dimensions = {
    Namespace = "taskmanager"
    Service   = "backend-svc"
    code      = "5XX"
  }

  # alarm_actions = [aws_sns_topic.alerts.arn]

  tags = {
    Name        = "${var.cluster_name}-backend-5xx"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── CloudWatch Metric Alarm: High Pod Memory ──────────────────────────────────
# Triggers when taskmanager pod memory utilization exceeds 85%
# (a sign that pods may be approaching OOMKill limits).
resource "aws_cloudwatch_metric_alarm" "pod_high_memory" {
  alarm_name          = "${var.cluster_name}-pod-high-memory"
  alarm_description   = "One or more pods in taskmanager namespace are using >85% memory. Risk of OOMKill eviction."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "pod_memory_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  treat_missing_data  = "notBreaching"

  dimensions = {
    Namespace   = "taskmanager"
    ClusterName = var.cluster_name
  }

  # alarm_actions = [aws_sns_topic.alerts.arn]

  tags = {
    Name        = "${var.cluster_name}-pod-high-memory"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
