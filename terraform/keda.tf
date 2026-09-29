# ─── KEDA + Metrics Server — Migrated to GitOps ──────────────────────────────
#
# MIGRATED TO GITOPS:
#   Both Helm releases have been migrated to ArgoCD GitOps management:
#     gitops/platform/keda.yaml
#
#   Migrated resources (removed from Terraform):
#     - helm_release.metrics_server
#     - helm_release.keda
#
# Sync wave ordering ensures correct startup:
#   Wave 1: metrics-server (kube-system) — required by HPA
#   Wave 2: keda (keda namespace) — depends on Metrics Server
#
# To modify KEDA or Metrics Server settings:
#   Edit gitops/platform/keda.yaml and git push.
#   ArgoCD will apply the change automatically.
# ──────────────────────────────────────────────────────────────────────────────
