# ─── Monitoring Stack — Migrated to GitOps ────────────────────────────────────
#
# MIGRATED TO GITOPS:
#   The kube-prometheus-stack Helm release has been migrated to ArgoCD GitOps:
#     gitops/platform/monitoring.yaml
#
#   Migrated resources (removed from Terraform):
#     - random_password.grafana_admin
#     - kubernetes_namespace.monitoring
#     - helm_release.kube_prometheus_stack
#
# The 'monitoring' namespace is now created by ArgoCD via CreateNamespace=true.
# The gp3 StorageClass (previously in efk.tf) is now in terraform/storage.tf.
#
# Grafana admin password:
#   After deployment, retrieve from the Kubernetes secret:
#     kubectl get secret -n monitoring kube-prometheus-stack-grafana \
#       -o jsonpath="{.data.admin-password}" | base64 -d
#
# To modify monitoring settings:
#   Edit gitops/platform/monitoring.yaml and git push.
#   ArgoCD will apply the change automatically.
# ──────────────────────────────────────────────────────────────────────────────
