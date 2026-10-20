# ─── EFK Logging Stack — Migrated to GitOps ──────────────────────────────────
#
# MIGRATED TO GITOPS:
#   All three EFK Helm releases have been migrated to ArgoCD GitOps management:
#     gitops/platform/efk.yaml (contains all three applications)
#
#   Migrated resources (removed from Terraform):
#     - kubernetes_namespace.logging
#     - helm_release.elasticsearch
#     - helm_release.fluent_bit
#     - helm_release.kibana
#
# IMPORTANT — StorageClass:
#   kubernetes_storage_class.gp3 has been MOVED to terraform/storage.tf
#   (shared dependency for both Elasticsearch and Prometheus PVCs)
#
# The 'logging' namespace is now created by ArgoCD via CreateNamespace=true.
# Sync waves ensure Elasticsearch (wave 2) is ready before Fluent Bit and
# Kibana (wave 3) attempt to connect.
#
# To modify EFK settings:
#   Edit gitops/platform/efk.yaml and git push.
#   ArgoCD will apply the change automatically within 3 minutes.
# ──────────────────────────────────────────────────────────────────────────────
