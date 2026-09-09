# ─── Dual Ingress Controllers (Public + Internal) ─────────────────────────────
#
# Deploys TWO separate nginx Ingress Controllers via Helm:
#
#   1. nginx-public  — internet-facing AWS NLB (handles Frontend + Backend API)
#   2. nginx-internal — internal-only AWS NLB (handles Grafana + Kibana + ArgoCD)
#
# Why two controllers?
#   Each controller provisions its OWN dedicated AWS Load Balancer, so:
#   - The internal LB gets a VPC-private IP (10.x.x.x) only → zero public attack surface
#   - Even a misconfigured Ingress using "nginx-internal" will NEVER get a public IP
#
# Access model (no custom domain → path-based routing):
#   Public  : http://<public-nlb-hostname>/       → Frontend
#             http://<public-nlb-hostname>/api/    → PostgREST Backend
#   Internal: http://<internal-nlb-ip>/grafana/   → Grafana
#             http://<internal-nlb-ip>/kibana/     → Kibana
#             http://<internal-nlb-ip>/argocd/     → ArgoCD
#
# Access to the internal LB requires one of:
#   - AWS Client VPN / WireGuard / Tailscale (connects laptop to 10.0.0.0/16)
#   - AWS SSM Session Manager port-forwarding (zero open ports needed)
#   - kubectl port-forward (dev convenience)
# ──────────────────────────────────────────────────────────────────────────────

# ── Shared Namespace ──────────────────────────────────────────────────────────
resource "kubernetes_namespace" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
    labels = {
      purpose = "ingress-control"
    }
  }

  depends_on = [module.eks]
}

# ── 1. Public Ingress Controller ─────────────────────────────────────────────
# Provisions an internet-facing AWS Network Load Balancer (NLB) in the PUBLIC
# subnets. All user-facing app traffic (Frontend + Backend API) enters here.
resource "helm_release" "ingress_nginx_public" {
  name       = "nginx-public"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.10.1"
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name
  timeout    = 300
  wait       = true

  values = [yamlencode({
    controller = {
      # Unique class name so only Ingress objects with ingressClassName: nginx-public
      # are served by this controller
      ingressClass       = "nginx-public"
      ingressClassByName = true

      ingressClassResource = {
        name            = "nginx-public"
        enabled         = true
        default         = false
        controllerValue = "k8s.io/nginx-public"
      }

      # Launch an AWS NLB (internet-facing) in public subnets with optional SSL termination
      service = {
        type = "LoadBalancer"
        targetPorts = {
          http  = "http"
          https = "http" # NLB terminates SSL on 443, forwards plaintext HTTP to Nginx on 80
        }
        annotations = merge(
          {
            "service.beta.kubernetes.io/aws-load-balancer-type"            = "nlb"
            "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
            "service.beta.kubernetes.io/aws-load-balancer-name"            = "${var.cluster_name}-public-nlb"
            "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
          },
          var.ssl_enabled ? {
            "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"               = aws_acm_certificate_validation.app[0].certificate_arn
            "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"              = "https"
            "service.beta.kubernetes.io/aws-load-balancer-backend-protocol"       = "tcp"
            "service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy" = "ELBSecurityPolicy-TLS13-1-2-2021-06"
          } : {}
        )
      }

      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }

      # Pin Ingress controller to system_nodes
      nodeSelector = {
        nodegroup = "system"
      }

      config = {
        use-real-ip           = "true"
        use-forwarded-headers = "true"
      }
    }
  })]

  depends_on = [
    kubernetes_namespace.ingress_nginx,
    aws_acm_certificate_validation.app,
  ]
}

# ── 2. Internal Ingress Controller ────────────────────────────────────────────
# Provisions an INTERNAL-ONLY AWS Network Load Balancer in the PRIVATE subnets.
# It has no public IP — only reachable from within the VPC (via VPN or SSM).
# Routes admin traffic to Grafana, Kibana, and ArgoCD.
resource "helm_release" "ingress_nginx_internal" {
  name       = "nginx-internal"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.10.1"
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name
  timeout    = 300
  wait       = true

  values = [yamlencode({
    controller = {
      # Unique class name — only Ingress objects with ingressClassName: nginx-internal
      # are served by this controller
      ingressClass       = "nginx-internal"
      ingressClassByName = true

      ingressClassResource = {
        name            = "nginx-internal"
        enabled         = true
        default         = false
        controllerValue = "k8s.io/nginx-internal"
      }

      # Launch an internal AWS NLB — NO public IP, VPC-only
      service = {
        type = "LoadBalancer"
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-type"            = "nlb"
          "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internal"
          "service.beta.kubernetes.io/aws-load-balancer-name"            = "${var.cluster_name}-internal-nlb"
          "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
        }
      }

      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }

      # Pin Ingress controller to system_nodes
      nodeSelector = {
        nodegroup = "system"
      }

      # Allow cross-namespace service references (needed for Grafana/Kibana/ArgoCD
      # Ingress rules that reference services in other namespaces)
      config = {
        allow-snippet-annotations = "true"
        enable-real-ip            = "true"
      }
    }
  })]

  depends_on = [kubernetes_namespace.ingress_nginx]
}
