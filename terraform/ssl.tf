# ─── SSL / TLS & Route 53 DNS Configuration ─────────────────────────────────────
#
# Automates production HTTPS for the Task Manager application:
#   1. Creates an AWS Route 53 Hosted Zone for the domain
#   2. Provisions a free AWS Certificate Manager (ACM) SSL/TLS certificate
#   3. Auto-inserts DNS CNAME validation records into Route 53 for instant issuance
#   4. Waits for certificate validation to complete
#   5. Provisions a Route 53 ALIAS A-Record pointing tasks.domain → Public NLB
#
# TLS is terminated at the AWS NLB layer for optimal performance and zero pod overhead.
# ──────────────────────────────────────────────────────────────────────────────

# ─── 1. Route 53 Hosted Zone ───────────────────────────────────────────────────
resource "aws_route53_zone" "main" {
  count = var.ssl_enabled ? 1 : 0
  name  = var.domain_name

  tags = {
    Name        = "${var.cluster_name}-hosted-zone"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ─── 2. AWS Certificate Manager (ACM) Certificate ─────────────────────────────
resource "aws_acm_certificate" "app" {
  count             = var.ssl_enabled ? 1 : 0
  domain_name       = "${var.app_subdomain}.${var.domain_name}"
  validation_method = "DNS"

  # Keep old certificate active until new certificate is validated during renewal
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.cluster_name}-acm-cert"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ─── 3. Auto-insert DNS Validation CNAME Records into Route 53 ─────────────────
# ACM provides cryptographic domain validation tokens. This resource automatically
# publishes the CNAME records into Route 53 so AWS can issue the certificate without
# requiring any manual DNS entries.
resource "aws_route53_record" "acm_validation" {
  for_each = var.ssl_enabled ? {
    for dvo in aws_acm_certificate.app[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = aws_route53_zone.main[0].zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

# ─── 4. Certificate Validation Waiter ─────────────────────────────────────────
# Blocks dependent resources (like the Public NLB) until ACM marks the certificate as ISSUED.
resource "aws_acm_certificate_validation" "app" {
  count                   = var.ssl_enabled ? 1 : 0
  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}

# ─── 5. Route 53 ALIAS A-Record → Public NLB ──────────────────────────────────
# Routes https://tasks.domain.com directly to the AWS Network Load Balancer.
# AWS Route 53 ALIAS records are free of query charges and update automatically.
data "aws_lb" "public_nlb" {
  count = (var.ssl_enabled || var.cdn_enabled) ? 1 : 0
  name  = "${var.cluster_name}-public-nlb"

  depends_on = [helm_release.ingress_nginx_public]
}

resource "aws_route53_record" "app_alias" {
  count   = (var.ssl_enabled && !var.cdn_enabled) ? 1 : 0
  zone_id = aws_route53_zone.main[0].zone_id
  name    = "${var.app_subdomain}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = data.aws_lb.public_nlb[0].dns_name
    zone_id                = data.aws_lb.public_nlb[0].zone_id
    evaluate_target_health = true
  }
}

