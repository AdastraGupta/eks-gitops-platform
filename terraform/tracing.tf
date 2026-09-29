# ─── Jaeger Distributed Tracing — Migrated to GitOps ─────────────────────────
#
# MIGRATED TO GITOPS:
#   The Jaeger Helm release has been migrated to ArgoCD GitOps management:
#     gitops/platform/tracing.yaml
#
#   Migrated resources (removed from Terraform):
#     - kubernetes_namespace.tracing
#     - helm_release.jaeger
#
# The 'tracing' namespace is now created by ArgoCD via CreateNamespace=true.
# Jaeger runs at sync wave 3 (after Elasticsearch, which it uses for storage).
#
# Access:
#   Jaeger UI: http://<internal-nlb-ip>/jaeger  (requires VPN or kubectl port-forward)
#
# Application instrumentation:
#   OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger-collector.tracing.svc.cluster.local:4318
#
# To modify tracing settings:
#   Edit gitops/platform/tracing.yaml and git push.
#   ArgoCD will apply the change automatically.
# ──────────────────────────────────────────────────────────────────────────────
