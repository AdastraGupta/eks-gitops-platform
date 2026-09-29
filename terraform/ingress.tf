# ─── Ingress Controllers — Namespace Declaration ──────────────────────────────
#
# MIGRATED TO GITOPS:
#   Both nginx-public and nginx-internal Helm releases have been migrated to
#   ArgoCD GitOps management:
#     - gitops/platform/ingress-public.yaml
#     - gitops/platform/ingress-internal.yaml
#
# The 'ingress-nginx' namespace is now created by ArgoCD via
# the CreateNamespace=true syncOption. No Terraform namespace resource needed.
#
# This file is kept as documentation. It can be safely deleted once the
# GitOps migration has been confirmed working on a live cluster.
#
# Access model (managed via ArgoCD):
#   Public  : http://<public-nlb-hostname>/       → Frontend
#             http://<public-nlb-hostname>/api/    → PostgREST Backend
#   Internal: http://<internal-nlb-ip>/grafana/   → Grafana
#             http://<internal-nlb-ip>/kibana/     → Kibana
#             http://<internal-nlb-ip>/argocd/     → ArgoCD
#
# To modify ingress controller settings:
#   Edit the values section in gitops/platform/ingress-public.yaml
#   or gitops/platform/ingress-internal.yaml and git push.
#   ArgoCD will apply the change automatically within 3 minutes.
# ──────────────────────────────────────────────────────────────────────────────
