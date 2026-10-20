# ─── Cluster Info ──────────────────────────────────────────────────────────────

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "API server endpoint of the EKS cluster."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the EKS cluster."
  value       = module.eks.cluster_version
}

output "node_groups_status_command" {
  description = "Verify both system_nodes and app_nodes are Ready and correctly labelled."
  value       = "kubectl get nodes -L nodegroup,role,kubernetes.io/arch --sort-by=.metadata.labels.nodegroup"
}

output "workload_placement_command" {
  description = "Show which node group each pod is scheduled on across all namespaces."
  value       = "kubectl get pods -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName' --sort-by=.metadata.namespace"
}

# ─── Networking ────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "ID of the VPC created for this cluster."
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "IDs of the private subnets (where EKS nodes run)."
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "IDs of the public subnets (where load balancers are placed)."
  value       = module.vpc.public_subnets
}

# ─── Next Steps ────────────────────────────────────────────────────────────────

output "kubeconfig_command" {
  description = "Run this command to configure kubectl to talk to your new EKS cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "argocd_admin_password_command" {
  description = "Retrieve the auto-generated ArgoCD admin password after terraform apply."
  value       = var.argocd_enabled ? "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d" : "ArgoCD is disabled (argocd_enabled = false)"
}

output "argocd_access_info" {
  description = "Access ArgoCD UI via the internal Ingress at /argocd (requires VPN or port-forward)."
  value       = var.argocd_enabled ? "kubectl port-forward svc/nginx-internal-ingress-nginx-controller 8080:80 -n ingress-nginx  # then open http://localhost:8080/argocd" : "ArgoCD is disabled (argocd_enabled = false)"
}

# ─── RDS PostgreSQL ────────────────────────────────────────────────────────────

output "rds_endpoint" {
  description = "Full RDS connection endpoint (host:port). Use this in the PGRST_DB_URI connection string."
  value       = aws_db_instance.postgres.endpoint
}

output "rds_address" {
  description = "Hostname of the RDS instance. Use as the ExternalName in the Kubernetes postgres-svc."
  value       = aws_db_instance.postgres.address
}

output "rds_port" {
  description = "Port of the RDS PostgreSQL instance (5432)."
  value       = aws_db_instance.postgres.port
}

output "rds_db_name" {
  description = "Name of the PostgreSQL database created on the RDS instance."
  value       = aws_db_instance.postgres.db_name
}

output "rds_username" {
  description = "Master username for the RDS PostgreSQL instance."
  value       = aws_db_instance.postgres.username
}

output "rds_k8s_external_service_command" {
  description = "Apply this manifest to wire the Kubernetes postgres-svc to the RDS endpoint after terraform apply."
  value       = <<-EOT
    # After 'terraform apply', patch the Kubernetes ExternalName service:
    kubectl patch svc postgres-svc -n taskmanager \
      -p '{"spec":{"type":"ExternalName","externalName":"${aws_db_instance.postgres.address}","ports":[{"port":5432,"targetPort":5432}]}}'
  EOT
}


# ─── CloudWatch Observability ──────────────────────────────────────────────────

output "cloudwatch_dashboard_name" {
  description = "Name of the CloudWatch Dashboard provisioned by Terraform."
  value       = aws_cloudwatch_dashboard.taskmanager.dashboard_name
}

output "cloudwatch_dashboard_url" {
  description = "Direct AWS Console URL to open the CloudWatch Dashboard after terraform apply."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.taskmanager.dashboard_name}"
}

# ─── EFK Logging Stack (ArgoCD-managed) ────────────────────────────────────────
# EFK is now managed by ArgoCD via gitops/platform/efk.yaml

output "public_lb_url_command" {
  description = "Get the Public NLB hostname for frontend + backend API access."
  value       = "kubectl get svc nginx-public-ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}

output "internal_lb_url_command" {
  description = "Get the Internal NLB hostname for Grafana, Kibana, ArgoCD (VPC-only, not publicly reachable)."
  value       = "kubectl get svc nginx-internal-ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}

output "kibana_access_info" {
  description = "Kibana is served via the internal NLB at /kibana (managed by ArgoCD). Access via VPN or port-forward."
  value       = "kubectl port-forward svc/nginx-internal-ingress-nginx-controller 8080:80 -n ingress-nginx  # then open http://localhost:8080/kibana"
}

output "efk_status_command" {
  description = "Check the health of all EFK stack pods (deployed by ArgoCD from gitops/platform/efk.yaml)."
  value       = "kubectl get pods -n logging"
}

output "elasticsearch_health_command" {
  description = "Check the Elasticsearch cluster health."
  value       = "kubectl exec -n logging elasticsearch-master-0 -- curl -s http://localhost:9200/_cluster/health?pretty"
}

output "efk_argocd_apps" {
  description = "Check ArgoCD sync status for all EFK applications."
  value       = "kubectl get applications efk-elasticsearch efk-fluent-bit efk-kibana -n argocd"
}


# ─── Prometheus + Grafana Monitoring (ArgoCD-managed) ───────────────────────────
# Monitoring is now managed by ArgoCD via gitops/platform/monitoring.yaml

output "grafana_access_command" {
  description = "Grafana is served via the internal NLB at /grafana (managed by ArgoCD). Access via VPN or port-forward."
  value       = "kubectl port-forward svc/nginx-internal-ingress-nginx-controller 8080:80 -n ingress-nginx  # then open http://localhost:8080/grafana"
}

output "monitoring_status_command" {
  description = "Command to check the health of all Prometheus + Grafana monitoring pods."
  value       = "kubectl get pods -n monitoring"
}

output "monitoring_argocd_app" {
  description = "Check ArgoCD sync status for Prometheus + Grafana monitoring stack."
  value       = "kubectl get application kube-prometheus-stack -n argocd"
}

# ─── Jaeger Distributed Tracing (ArgoCD-managed) ──────────────────────────────
# Tracing is now managed by ArgoCD via gitops/platform/tracing.yaml

output "jaeger_access_command" {
  description = "Jaeger UI is served via the internal NLB at /jaeger. Access via VPN or port-forward."
  value       = "kubectl port-forward svc/nginx-internal-ingress-nginx-controller 8080:80 -n ingress-nginx  # then open http://localhost:8080/jaeger"
}

output "tracing_status_command" {
  description = "Command to check the health of all Jaeger tracing pods."
  value       = "kubectl get pods -n tracing"
}

output "tracing_argocd_app" {
  description = "Check ArgoCD sync status for Jaeger distributed tracing."
  value       = "kubectl get application jaeger -n argocd"
}

# ─── K8sGPT — AI-Powered SRE (AWS Bedrock) ───────────────────────────────────

output "k8sgpt_status_command" {
  description = "Check K8sGPT Operator pod health, the K8sGPT CRD config, and AI scan results."
  value       = var.k8sgpt_enabled ? "kubectl get pods,k8sgpt,results -n k8sgpt" : "K8sGPT is disabled (k8sgpt_enabled = false)"
}

output "k8sgpt_results_command" {
  description = "View all AI-generated incident analysis results in full YAML detail."
  value       = var.k8sgpt_enabled ? "kubectl get results -n k8sgpt -o yaml" : "K8sGPT is disabled (k8sgpt_enabled = false)"
}

output "k8sgpt_bedrock_model" {
  description = "AWS Bedrock model currently configured for K8sGPT incident analysis."
  value       = var.k8sgpt_enabled ? var.k8sgpt_bedrock_model : "K8sGPT is disabled (k8sgpt_enabled = false)"
}

# ─── Karpenter Node Autoscaler ────────────────────────────────────────────────

output "karpenter_status_command" {
  description = "Check Karpenter controller pod health and active NodePool / EC2NodeClass resources."
  value       = var.karpenter_enabled ? "kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter && kubectl get nodepools,ec2nodeclasses" : "Karpenter is disabled (karpenter_enabled = false)"
}

output "karpenter_nodes_command" {
  description = "List all nodes provisioned by Karpenter with their instance type and AZ."
  value       = var.karpenter_enabled ? "kubectl get nodes -l karpenter.sh/nodepool=app-nodepool -o wide" : "Karpenter is disabled (karpenter_enabled = false)"
}

output "karpenter_interruption_queue" {
  description = "SQS queue ARN used for Spot interruption and EC2 state-change event handling."
  value       = var.karpenter_enabled ? aws_sqs_queue.karpenter_interruption[0].arn : "Karpenter is disabled (karpenter_enabled = false)"
}

# ─── KEDA Event-Driven Autoscaler (ArgoCD-managed) ─────────────────────────────
# KEDA is now managed by ArgoCD via gitops/platform/keda.yaml

output "keda_status_command" {
  description = "Check KEDA controller pod health and all active ScaledObjects in the cluster."
  value       = "kubectl get pods -n keda && kubectl get scaledobjects -A"
}

output "keda_hpa_command" {
  description = "View all HPA resources managed by KEDA for the taskmanager namespace."
  value       = "kubectl get hpa -n taskmanager"
}

output "keda_argocd_apps" {
  description = "Check ArgoCD sync status for KEDA and Metrics Server."
  value       = "kubectl get applications keda metrics-server -n argocd"
}

output "autoscaling_observe_command" {
  description = "Watch pod scaling events in real time across the taskmanager namespace."
  value       = "kubectl get pods -n taskmanager -w"
}

# ─── SSL / DNS (ACM + Route 53) ────────────────────────────────────────────────

output "app_https_url" {
  description = "Public HTTPS URL for the Task Manager application."
  value       = var.ssl_enabled ? "https://${var.app_subdomain}.${var.domain_name}" : "SSL is disabled (ssl_enabled = false)"
}

output "acm_certificate_arn" {
  description = "ARN of the AWS ACM SSL certificate provisioned for the application."
  value       = var.ssl_enabled ? aws_acm_certificate_validation.app[0].certificate_arn : "SSL is disabled (ssl_enabled = false)"
}

output "route53_zone_id" {
  description = "Route 53 Hosted Zone ID for the domain."
  value       = var.ssl_enabled ? aws_route53_zone.main[0].zone_id : "SSL is disabled (ssl_enabled = false)"
}

output "route53_nameservers" {
  description = "Route 53 authoritative nameservers. Delegate these NS records at your domain registrar."
  value       = var.ssl_enabled ? aws_route53_zone.main[0].name_servers : []
}

# ─── CloudFront CDN ────────────────────────────────────────────────────────────

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name (e.g. d1234abcd.cloudfront.net). Use this to verify CDN is working before DNS cutover."
  value       = var.cdn_enabled ? aws_cloudfront_distribution.frontend[0].domain_name : "CDN is disabled (cdn_enabled = false)"
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID. Use this to create cache invalidations on deploy: aws cloudfront create-invalidation --distribution-id <ID> --paths '/*'"
  value       = var.cdn_enabled ? aws_cloudfront_distribution.frontend[0].id : "CDN is disabled (cdn_enabled = false)"
}

output "cloudfront_invalidation_command" {
  description = "Run this after each frontend deployment to purge stale cached assets from all CloudFront edge PoPs."
  value       = var.cdn_enabled ? "aws cloudfront create-invalidation --distribution-id ${aws_cloudfront_distribution.frontend[0].id} --paths '/index.html'" : "CDN is disabled (cdn_enabled = false)"
}

output "cdn_frontend_url" {
  description = "Public HTTPS URL served via CloudFront CDN (same as app_https_url after DNS cutover)."
  value       = (var.cdn_enabled && var.ssl_enabled) ? "https://${var.app_subdomain}.${var.domain_name}" : (var.cdn_enabled ? "https://${aws_cloudfront_distribution.frontend[0].domain_name}" : "CDN is disabled (cdn_enabled = false)")
}
