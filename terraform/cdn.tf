# ─── AWS CloudFront CDN for React Frontend ────────────────────────────────────
#
# Puts a global CloudFront distribution in front of the public NLB to:
#   1. Cache static assets (JS/CSS/images) at 400+ AWS edge PoPs worldwide
#   2. Terminate HTTPS with an ACM certificate (SSL offload at edge, not pods)
#   3. Serve SPA fallback: CloudFront returns index.html on 404 so React
#      Router handles client-side navigation (e.g. /tasks/42 on hard refresh)
#   4. Compress responses with gzip/brotli at the edge for free
#
# Cache TTL strategy:
#   /static/* (hashed filenames e.g. main.abc123.js)  → 1 year (immutable)
#   /index.html                                         → 0s    (always revalidate)
#   /api/*                                              → 0s    (never cache API calls)
#   All other paths                                     → 0s    (revalidate)
#
# Architecture:
#   Browser → CloudFront (edge) →[miss]→ Public NLB → nginx pod → index.html
#                               →[hit] → cached JS/CSS (EKS never touched)
#
# Controlled by: var.cdn_enabled (default: true when ssl_enabled is true)
# ──────────────────────────────────────────────────────────────────────────────

# ── 1. Origin Request Policy ──────────────────────────────────────────────────
# Controls which headers/cookies/query strings CloudFront forwards to the origin.
# For static assets we forward nothing (maximises cache hit ratio).
resource "aws_cloudfront_origin_request_policy" "static_assets" {
  count = var.cdn_enabled ? 1 : 0
  name  = "${var.cluster_name}-static-assets-origin-policy"

  cookies_config {
    cookie_behavior = "none"
  }
  headers_config {
    header_behavior = "none"
  }
  query_strings_config {
    query_string_behavior = "none"
  }
}

# ── 2. Cache Policy — Static Assets (long TTL) ────────────────────────────────
# Applied to /static/* — CRA/Vite puts all hashed bundles here.
# 1-year TTL is safe because filenames include a content hash.
resource "aws_cloudfront_cache_policy" "static_assets" {
  count       = var.cdn_enabled ? 1 : 0
  name        = "${var.cluster_name}-static-assets-cache-policy"
  default_ttl = 31536000 # 1 year (seconds)
  max_ttl     = 31536000
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
    enable_accept_encoding_gzip   = true # compress at edge
    enable_accept_encoding_brotli = true # brotli is ~20% smaller than gzip
  }
}

# ── 3. Cache Policy — No Cache (index.html + API responses) ───────────────────
# Applied to default behaviour — ensures fresh content on every request.
resource "aws_cloudfront_cache_policy" "no_cache" {
  count       = var.cdn_enabled ? 1 : 0
  name        = "${var.cluster_name}-no-cache-policy"
  default_ttl = 0
  max_ttl     = 0
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "all" # forward query strings to origin for API paths
    }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

# ── 4. Origin Request Policy — API (forward headers/cookies/query strings to backend) ───
# For API calls we forward auth headers, cookies, and query parameters to the backend.
resource "aws_cloudfront_origin_request_policy" "api" {
  count = var.cdn_enabled ? 1 : 0
  name  = "${var.cluster_name}-api-origin-policy"

  cookies_config {
    cookie_behavior = "all"
  }
  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Authorization", "Content-Type", "Accept", "Origin"]
    }
  }
  query_strings_config {
    query_string_behavior = "all"
  }
}

# ── 5. CloudFront Distribution ────────────────────────────────────────────────
resource "aws_cloudfront_distribution" "frontend" {
  count = var.cdn_enabled ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.cluster_name} React frontend CDN"
  default_root_object = "index.html"

  # Aliases: the custom domain (e.g. tasks.yourdomain.com) routes to CloudFront.
  # ACM cert must be in us-east-1 for CloudFront regardless of the cluster region.
  aliases = var.ssl_enabled ? ["${var.app_subdomain}.${var.domain_name}"] : []

  # ── Origin: Public NLB ──────────────────────────────────────────────────────
  origin {
    domain_name = data.aws_lb.public_nlb[0].dns_name
    origin_id   = "public-nlb"

    custom_origin_config {
      http_port  = 80
      https_port = 443
      # NLB → CloudFront communication is HTTP (within AWS network, no public internet).
      # HTTPS is only on the viewer (user) → CloudFront edge side.
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]

      # Increase timeout for Spring Boot cold starts
      origin_read_timeout      = 60
      origin_keepalive_timeout = 60
    }
  }

  # ── Cache Behaviour: /static/* (hashed JS/CSS/images, 1-year TTL) ──────────
  # Create React App places all hashed bundles in /static/js, /static/css, etc.
  # Vite places them in /assets/. Adjust path_pattern if using Vite.
  ordered_cache_behavior {
    path_pattern             = "/static/*"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "public-nlb"
    compress                 = true
    viewer_protocol_policy   = "redirect-to-https"
    cache_policy_id          = aws_cloudfront_cache_policy.static_assets[0].id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.static_assets[0].id
  }

  # ── Cache Behaviour: /api/* (backend REST, never cache) ───────────────────
  # API responses must never be cached — each call fetches live data.
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "public-nlb"
    compress                 = false
    viewer_protocol_policy   = "redirect-to-https"
    cache_policy_id          = aws_cloudfront_cache_policy.no_cache[0].id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.api[0].id
  }

  # ── Default Cache Behaviour: index.html + all other paths (no cache) ───────
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "public-nlb"
    compress               = true
    viewer_protocol_policy = "redirect-to-https"
    cache_policy_id        = aws_cloudfront_cache_policy.no_cache[0].id
  }

  # ── React Router SPA Fallback ─────────────────────────────────────────────
  # When a user hard-refreshes on /tasks/42, the origin returns 404 (no file).
  # CloudFront intercepts the 404 and serves index.html with a 200 status,
  # allowing React Router to pick up the route and render the correct page.
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  # ── Geo Restrictions (none) ───────────────────────────────────────────────
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # ── SSL / TLS Certificate ─────────────────────────────────────────────────
  # CloudFront requires ACM certificates to be in us-east-1 (global edge).
  # The certificate ARN comes from ssl.tf (aws_acm_certificate_validation.app).
  #
  # Two dynamic blocks are used (only one fires at runtime) because Terraform
  # rejects null for string-typed attributes like ssl_support_method and
  # minimum_protocol_version — a ternary with null would cause a plan error.
  dynamic "viewer_certificate" {
    for_each = var.ssl_enabled ? [1] : []
    content {
      acm_certificate_arn      = aws_acm_certificate_validation.app[0].certificate_arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1.2_2021"
    }
  }

  dynamic "viewer_certificate" {
    for_each = var.ssl_enabled ? [] : [1]
    content {
      cloudfront_default_certificate = true
    }
  }

  # ── Logging (optional, to S3) ─────────────────────────────────────────────
  # Uncomment to enable CloudFront access logs in an S3 bucket.
  # dynamic "logging_config" {
  #   for_each = var.cdn_logging_enabled ? [1] : []
  #   content {
  #     bucket          = "${aws_s3_bucket.cdn_logs[0].bucket}.s3.amazonaws.com"
  #     prefix          = "cloudfront/"
  #     include_cookies = false
  #   }
  # }

  tags = {
    Name        = "${var.cluster_name}-frontend-cdn"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  depends_on = [
    data.aws_lb.public_nlb,
    aws_acm_certificate_validation.app,
  ]
}

# ── 6. Update Route 53 ALIAS to point to CloudFront (not NLB directly) ────────
# Before CDN: tasks.yourdomain.com → NLB (us-east-1 only)
# After CDN:  tasks.yourdomain.com → CloudFront (global edge PoPs)
#
# This REPLACES the Route 53 record in ssl.tf that points directly to the NLB.
# Only created when both ssl_enabled AND cdn_enabled are true.
resource "aws_route53_record" "app_cloudfront" {
  count   = (var.ssl_enabled && var.cdn_enabled) ? 1 : 0
  zone_id = aws_route53_zone.main[0].zone_id
  name    = "${var.app_subdomain}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend[0].domain_name
    zone_id                = aws_cloudfront_distribution.frontend[0].hosted_zone_id
    evaluate_target_health = false # CloudFront manages its own health
  }
}
