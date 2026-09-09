# ─── ArgoCD — GitOps Controller (Helm-managed) ────────────────────────────────
#
# Deploys ArgoCD via the official argo/argo-cd Helm chart.
#
# Replaces the previous manual bootstrap approach:
#   BEFORE: kubectl apply -n argocd -f .../install.yaml (manual step after TF)
#   AFTER : 100% automated via terraform apply (zero manual kubectl steps)
#
# Key configuration:
#   - server.service.type = ClusterIP   → No direct public LB; served via
#     nginx-internal Ingress at /argocd (internal NLB, VPC-only)
#   - server.insecure = true            → TLS terminated at internal Ingress
#   - MS Teams notifications            → Webhook + templates embedded in chart
#   - additionalApplications            → Auto-provisions the taskmanager app
#     so ArgoCD starts syncing k8s/ immediately after Terraform finishes
#
# Accessing ArgoCD:
#   kubectl port-forward svc/nginx-internal-ingress-nginx-controller \
#     8080:80 -n ingress-nginx
#   → http://localhost:8080/argocd
#   Username: admin
#   Password: kubectl -n argocd get secret argocd-initial-admin-secret \
#               -o jsonpath='{.data.password}' | base64 -d
# ──────────────────────────────────────────────────────────────────────────────

resource "helm_release" "argocd" {
  count = var.argocd_enabled ? 1 : 0

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.4.3" # ArgoCD v2.12.x
  namespace        = "argocd"
  create_namespace = true
  timeout          = 600
  wait             = true

  values = [yamlencode({

    # ── Global configuration ───────────────────────────────────────────────────
    global = {
      labels = {
        "app.kubernetes.io/part-of" = "argocd"
      }
      # Pin all ArgoCD pods (server, repo-server, controller, redis, notifications) to system_nodes
      nodeSelector = {
        nodegroup = "system"
      }
    }

    # ── ArgoCD Server ─────────────────────────────────────────────────────────
    server = {
      # Run HTTP (not HTTPS) — TLS is terminated at the nginx-internal Ingress
      insecure = true

      # ClusterIP — no public AWS LB; traffic arrives via nginx-internal at /argocd
      service = {
        type = "ClusterIP"
      }

      # Serve ArgoCD UI behind the /argocd subpath on the internal Ingress
      extraArgs = ["--rootpath=/argocd"]

      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }

      # ArgoCD config (replaces the old argocd-cm ConfigMap)
      config = {
        "url"                          = "http://internal-lb/argocd"
        "application.instanceLabelKey" = "argocd.argoproj.io/instance"
      }
    }

    # ── Application Controller ─────────────────────────────────────────────────
    controller = {
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "500m", memory = "1Gi" }
      }
    }

    # ── Repo Server ────────────────────────────────────────────────────────────
    repoServer = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "300m", memory = "256Mi" }
      }
    }

    # ── ApplicationSet Controller ──────────────────────────────────────────────
    applicationSet = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "128Mi" }
      }
    }

    # ── Redis ──────────────────────────────────────────────────────────────────
    redis = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }
    }

    # ── Notifications Controller (replaces manual k8s/argocd-notifications.yaml)
    # Injects all MS Teams templates + triggers directly via Helm values.
    # The webhook secret is created automatically from var.teams_webhook_url.
    notifications = {
      enabled = true

      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "128Mi" }
      }

      # Secret: stores the Teams webhook URL (replaces manual Secret creation)
      secret = {
        create = true
        items = {
          "msteams-webhook-url" = var.teams_webhook_url
        }
      }

      # CM: notification triggers and message templates
      cm = {
        create = true
        data = {
          # ── Service: MS Teams Webhook ─────────────────────────────────────
          "service.webhook.msteams" = <<-EOT
            url: $msteams-webhook-url
            headers:
              - name: Content-Type
                value: application/json
          EOT

          # ── Trigger: Sync Succeeded ───────────────────────────────────────
          "trigger.on-sync-succeeded" = <<-EOT
            - description: Application syncing has succeeded
              send:
                - app-sync-succeeded
              when: app.status.operationState != nil and app.status.operationState.phase in ['Succeeded']
          EOT

          # ── Trigger: Sync Failed ──────────────────────────────────────────
          "trigger.on-sync-failed" = <<-EOT
            - description: Application syncing has failed
              send:
                - app-sync-failed
              when: app.status.operationState != nil and app.status.operationState.phase in ['Error', 'Failed']
          EOT

          # ── Trigger: Health Degraded ──────────────────────────────────────
          "trigger.on-health-degraded" = <<-EOT
            - description: Application health status is degraded
              send:
                - app-health-degraded
              when: app.status.health.status == 'Degraded'
          EOT

          # ── Template: Sync Succeeded (Green Card) ─────────────────────────
          "template.app-sync-succeeded" = <<-EOT
            webhook:
              msteams:
                method: POST
                body: |
                  {
                    "@type": "MessageCard",
                    "@context": "http://schema.org/extensions",
                    "themeColor": "107C10",
                    "summary": "ArgoCD Sync Succeeded - {{.app.metadata.name}}",
                    "sections": [{
                      "activityTitle": "🔄 ArgoCD GitOps Sync Succeeded — {{.app.metadata.name}}",
                      "activitySubtitle": "Namespace: {{.app.spec.destination.namespace}} | Cluster: in-cluster",
                      "facts": [
                        { "name": "Application", "value": "{{.app.metadata.name}}" },
                        { "name": "Status", "value": "Synced & Healthy ✅" },
                        { "name": "Repository", "value": "{{.app.spec.source.repoURL}}" },
                        { "name": "Revision", "value": "{{.app.status.sync.revision}}" }
                      ],
                      "markdown": true
                    }],
                    "potentialAction": [{
                      "@type": "OpenUri",
                      "name": "Open ArgoCD",
                      "targets": [{ "os": "default", "uri": "http://internal-lb/argocd/applications/{{.app.metadata.name}}" }]
                    }]
                  }
          EOT

          # ── Template: Sync Failed (Red Card) ──────────────────────────────
          "template.app-sync-failed" = <<-EOT
            webhook:
              msteams:
                method: POST
                body: |
                  {
                    "@type": "MessageCard",
                    "@context": "http://schema.org/extensions",
                    "themeColor": "D83B01",
                    "summary": "ArgoCD Sync Failed - {{.app.metadata.name}}",
                    "sections": [{
                      "activityTitle": "❌ ArgoCD GitOps Sync Failed — {{.app.metadata.name}}",
                      "activitySubtitle": "Namespace: {{.app.spec.destination.namespace}}",
                      "facts": [
                        { "name": "Application", "value": "{{.app.metadata.name}}" },
                        { "name": "Status", "value": "Sync Failed ❌" },
                        { "name": "Message", "value": "{{.app.status.operationState.message}}" },
                        { "name": "Revision", "value": "{{.app.status.sync.revision}}" }
                      ],
                      "markdown": true
                    }],
                    "potentialAction": [{
                      "@type": "OpenUri",
                      "name": "Open ArgoCD",
                      "targets": [{ "os": "default", "uri": "http://internal-lb/argocd/applications/{{.app.metadata.name}}" }]
                    }]
                  }
          EOT

          # ── Template: Health Degraded (Orange Card) ────────────────────────
          "template.app-health-degraded" = <<-EOT
            webhook:
              msteams:
                method: POST
                body: |
                  {
                    "@type": "MessageCard",
                    "@context": "http://schema.org/extensions",
                    "themeColor": "E81123",
                    "summary": "ArgoCD Health Degraded - {{.app.metadata.name}}",
                    "sections": [{
                      "activityTitle": "⚠️ ArgoCD Application Degraded — {{.app.metadata.name}}",
                      "activitySubtitle": "Namespace: {{.app.spec.destination.namespace}}",
                      "facts": [
                        { "name": "Application", "value": "{{.app.metadata.name}}" },
                        { "name": "Health Status", "value": "Degraded ⚠️ (Check Pods/Events)" },
                        { "name": "Message", "value": "{{.app.status.health.message}}" }
                      ],
                      "markdown": true
                    }],
                    "potentialAction": [{
                      "@type": "OpenUri",
                      "name": "Open ArgoCD",
                      "targets": [{ "os": "default", "uri": "http://internal-lb/argocd/applications/{{.app.metadata.name}}" }]
                    }]
                  }
          EOT
        }
      }
    }

    # ── Auto-provision taskmanager Application ──────────────────────────────────
    # ArgoCD immediately starts syncing k8s/ from GitHub once Helm finishes.
    # Replaces the manual: kubectl apply -f k8s/argocd-app.yaml
    additionalApplications = [
      {
        name       = "taskmanager"
        namespace  = "argocd"
        project    = "default"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]

        labels = {
          app         = "taskmanager"
          environment = var.environment
        }

        annotations = {
          "notifications.argoproj.io/subscribe.on-sync-succeeded.msteams"  = ""
          "notifications.argoproj.io/subscribe.on-sync-failed.msteams"     = ""
          "notifications.argoproj.io/subscribe.on-health-degraded.msteams" = ""
        }

        source = {
          repoURL        = "https://github.com/AdastraGupta/3-tier-k8s-project.git"
          targetRevision = "main"

          # Points to Helm chart — NOT the old k8s/ raw manifests folder
          path = "charts/taskmanager"

          helm = {
            # Load base defaults first, then overlay environment-specific values.
            # var.environment resolves to: "dev", "staging", or "prod"
            valueFiles = [
              "values.yaml",
              "values-${var.environment}.yaml"
            ]
          }
        }

        destination = {
          server    = "https://kubernetes.default.svc"  # in-cluster ArgoCD (each cluster manages itself)
          namespace = "taskmanager"                      # Same namespace name on every cluster
        }

        syncPolicy = {
          automated = {
            # Auto-prune is DISABLED in prod to prevent accidental deletion of resources.
            # In dev/staging, prune is enabled so stale resources are cleaned up automatically.
            prune    = var.environment != "prod"
            selfHeal = true
          }
          syncOptions = [
            "CreateNamespace=true",
            "PrunePropagationPolicy=foreground",
            "PruneLast=true",
            "ServerSideApply=true",
          ]
          retry = {
            limit = 5
            backoff = {
              duration    = "5s"
              factor      = 2
              maxDuration = "3m"
            }
          }
        }
      }
    ]
  })]

  depends_on = [
    module.eks,
    helm_release.ingress_nginx_internal,
  ]
}
