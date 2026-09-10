# ─── terraform/secret.tf ──────────────────────────────────────────────────────
# Creates the Kubernetes Secret for the DB password on each cluster.
# This is Option B: Terraform manages the secret directly.
# The password is injected via TF_VAR_db_password in the CI/CD pipeline
# and is NEVER committed to Git.
# ──────────────────────────────────────────────────────────────────────────────


resource "kubernetes_namespace" "taskmanager" {
  metadata {
    name = "taskmanager"
    labels = {
      name                           = "taskmanager"
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_secret" "taskmanager_db" {
  metadata {
    name      = "taskmanager-db-secret"
    namespace = kubernetes_namespace.taskmanager.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "Terraform"
      "app.kubernetes.io/name"       = "taskmanager"
      "environment"                  = var.environment
    }
  }

  # Type "Opaque" is the standard type for arbitrary key-value secrets
  type = "Opaque"

  data = {
    # Key must match the secretKeyRef.key in backend-deployment.yaml
    password = var.db_password
  }

  # Recreate the secret if namespace or name changes
  lifecycle {
    ignore_changes = []
  }

  depends_on = [
    kubernetes_namespace.taskmanager,
  ]
}
