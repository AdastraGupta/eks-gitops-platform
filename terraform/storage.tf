# ─── Shared Storage — EBS gp3 StorageClass ────────────────────────────────────
#
# Provisions the EBS gp3 StorageClass used by ArgoCD-managed workloads:
#   - Elasticsearch  (10Gi EBS, deployed by gitops/platform/efk.yaml)
#   - Prometheus     (20Gi EBS, deployed by gitops/platform/monitoring.yaml)
#   - Alertmanager   ( 5Gi EBS, deployed by gitops/platform/monitoring.yaml)
#
# Why gp3?
#   - 20% cheaper than gp2
#   - Better baseline throughput (125 MiB/s vs 128 MiB/s at 1TB)
#   - Configurable IOPS/throughput independently of volume size
#
# Why Terraform (not ArgoCD)?
#   The StorageClass is a cluster-scoped resource that must exist BEFORE
#   ArgoCD deploys Elasticsearch and Prometheus PVCs. Terraform provisions
#   it during cluster bootstrap alongside the EBS CSI Driver add-on.
#
# Prerequisite:
#   EBS CSI Driver add-on must be enabled in eks.tf (installed as EKS add-on
#   with its own IRSA role so it can create/attach EBS volumes).
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      # Set as default StorageClass so PVCs without explicit storageClassName
      # automatically get gp3 volumes.
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
    labels = {
      purpose      = "observability-storage"
      "managed-by" = "terraform"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"               # Keep EBS volume even if PVC is deleted
  allow_volume_expansion = true                   # Allow resizing without pod restart
  volume_binding_mode    = "WaitForFirstConsumer" # Provision in the same AZ as the pod

  parameters = {
    type   = "gp3"
    fsType = "ext4"
  }

  depends_on = [module.eks]
}
