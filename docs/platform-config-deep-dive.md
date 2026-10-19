# Platform Configuration Deep Dive
### `gitops/platform/` — Every File Explained

> **How it all starts:** Terraform registers a single ArgoCD Application at bootstrap time
> (`gitops/bootstrap/platform-apps.yaml`). That root Application watches the `gitops/platform/`
> directory. Every `*.yaml` file you drop in there automatically becomes a deployed platform component — no Terraform changes needed.

---

## Table of Contents

1. [Bootstrap — How platform-apps.yaml wires everything together](#0-bootstrap--platform-appsyaml)
2. [ingress-public.yaml — Internet-facing NLB](#1-ingress-publicyaml--public-nginx-ingress-controller)
3. [ingress-internal.yaml — VPC-only NLB for admin tools](#2-ingress-internalyaml--internal-nginx-ingress-controller)
4. [istio.yaml — Service mesh, mTLS, and telemetry](#3-istioyaml--istio-service-mesh)
5. [monitoring.yaml — Prometheus, Grafana, Alertmanager](#4-monitoringyaml--prometheus--grafana-stack)
6. [efk.yaml — Log collection, storage, and visualization](#5-efkyaml--efk-logging-stack)
7. [tracing.yaml — Distributed tracing with Jaeger](#6-tracingyaml--jaeger-distributed-tracing)
8. [keda.yaml — Event-driven autoscaling](#7-kedayaml--keda--metrics-server)
9. [Sync Wave Execution Order](#sync-wave-execution-order)
10. [Node Placement Strategy](#node-placement-strategy)
11. [Overall Observability Data Flow](#overall-observability-data-flow)

---

## 0. Bootstrap — `platform-apps.yaml`

**File:** [`gitops/bootstrap/platform-apps.yaml`](file:///c:/Users/Shivam.Gupta/OneDrive%20-%20Adastra,%20s.r.o/Desktop/Github/eks-gitops-platform/gitops/bootstrap/platform-apps.yaml)

This is the **"App of Apps"** root. It is the single entry-point for all platform tooling.

### How it works

```
Terraform (helm_release.argocd)
    └─► Registers platform-apps Application in ArgoCD
            └─► ArgoCD watches gitops/platform/*.yaml
                    ├─► ingress-public.yaml    → deploys nginx-public
                    ├─► ingress-internal.yaml  → deploys nginx-internal
                    ├─► istio.yaml             → deploys istio-base + istiod
                    ├─► monitoring.yaml        → deploys kube-prometheus-stack
                    ├─► efk.yaml               → deploys elasticsearch + fluent-bit + kibana
                    ├─► tracing.yaml           → deploys jaeger
                    └─► keda.yaml              → deploys metrics-server + keda
```

### Key settings

| Setting | Value | Why |
|---|---|---|
| `path` | `gitops/platform` | ArgoCD watches this whole directory |
| `targetRevision` | `main` | Tracks the main branch continuously |
| `prune: true` | Enabled | Deleting a yaml from this dir removes the tool from the cluster |
| `selfHeal: true` | Enabled | Manual `kubectl` edits are automatically reverted |

> [!IMPORTANT]
> To **add a new platform tool**, simply create `gitops/platform/<tool>.yaml` and push to `main`.
> ArgoCD picks it up automatically. **No Terraform required.**

### ArgoCD Finalizer (on every Application)
Every Application in `gitops/platform/` carries:
```yaml
finalizers:
  - resources-finalizer.argocd.argoproj.io
```
This is a **cascade-delete guard**. When an ArgoCD Application is deleted (e.g. via `prune`), ArgoCD will first delete **all Kubernetes resources it owns** (Deployments, Services, PVCs, etc.) before removing the Application object itself. Without this finalizer, deleting the Application leaves orphaned resources in the cluster.

### ServerSideApply — Why It's Used on Almost Every Application
Several charts (`kube-prometheus-stack`, `istio`, `keda`, `elasticsearch`, `ingress-nginx`, `jaeger`) use:
```yaml
syncOptions:
  - ServerSideApply=true
```
These charts include very large CRD objects (e.g. PrometheusRule, IstioOperator). The default **client-side apply** strategy stores the full `last-applied-configuration` annotation on every object — this annotation has a **256 KB limit**, which large CRDs exceed, causing apply to fail. Server-side apply moves the field ownership tracking to the API server, bypassing this limit entirely.

---

## 1. `ingress-public.yaml` — Public Nginx Ingress Controller

**File:** [`gitops/platform/ingress-public.yaml`](file:///c:/Users/Shivam.Gupta/OneDrive%20-%20Adastra,%20s.r.o/Desktop/Github/eks-gitops-platform/gitops/platform/ingress-public.yaml) | **Sync Wave: 1** | **Namespace:** `ingress-nginx`

### Purpose
Deploys an **internet-facing** AWS Network Load Balancer (NLB) to accept all **user traffic** into the cluster. This is the entry point for the React frontend and the PostgREST backend API.

### Traffic Flow
```
Internet
  └─► AWS NLB (public subnet, public IP)
        └─► nginx-public Ingress Controller (Pod on system node)
              ├─► /api/  → backend Service (taskmanager namespace)
              └─► /      → frontend Service (taskmanager namespace)
```

### Key Configuration Decisions

| Setting | Value | Explanation |
|---|---|---|
| `ingressClass` | `nginx-public` | Only Ingress resources with `ingressClassName: nginx-public` are routed here |
| `controllerValue` | `k8s.io/nginx-public` | Unique controller identifier — prevents conflict with nginx-internal |
| `aws-load-balancer-scheme` | `internet-facing` | Creates a public-IP NLB in the PUBLIC subnets |
| `aws-load-balancer-nlb-target-type` | `ip` | Routes directly to Pod IPs, bypassing NodePort — more efficient |
| `targetPorts.https: http` | Enabled | NLB terminates SSL on port 443 and forwards plain HTTP to Nginx on 80 |
| `use-real-ip: "true"` | Enabled | Nginx preserves the original client IP in logs/headers |
| `use-forwarded-headers: "true"` | Enabled | Respects `X-Forwarded-For` from NLB |

### SSL Termination
SSL is handled **at the NLB level** using an ACM certificate. The commented annotations below are added when `ssl_enabled=true` (managed in `terraform/ssl.tf` and `terraform/cdn.tf`):
```yaml
service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "<ACM_CERT_ARN>"
service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "https"
service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy: "ELBSecurityPolicy-TLS13-1-2-2021-06"
```

---

## 2. `ingress-internal.yaml` — Internal Nginx Ingress Controller

**File:** [`gitops/platform/ingress-internal.yaml`](file:///c:/Users/Shivam.Gupta/OneDrive%20-%20Adastra,%20s.r.o/Desktop/Github/eks-gitops-platform/gitops/platform/ingress-internal.yaml) | **Sync Wave: 1** | **Namespace:** `ingress-nginx`

### Purpose
Deploys a **VPC-only** NLB for **admin and observability dashboards**. It has no public IP — only accessible from inside the VPC (via VPN, SSM, or `kubectl port-forward`).

### Access Model
```
VPN / SSM Tunnel / kubectl port-forward
  └─► AWS NLB (PRIVATE subnet, VPC-only)
        └─► nginx-internal Ingress Controller (Pod on system node)
              ├─► /grafana/   → Grafana (monitoring namespace)
              ├─► /kibana/    → Kibana (logging namespace)
              ├─► /argocd/    → ArgoCD UI (argocd namespace)
              └─► /jaeger/    → Jaeger Query UI (tracing namespace)
```

### Key Configuration Decisions

| Setting | Value | Explanation |
|---|---|---|
| `ingressClass` | `nginx-internal` | Isolated from the public controller — separate routing domain |
| `aws-load-balancer-scheme` | `internal` | Creates a **private-IP** NLB — no public internet exposure |
| `allow-snippet-annotations` | `"true"` | Required to use Nginx `configuration-snippet` in Ingress objects (needed for path rewrites to cross-namespace services like Grafana/Kibana) |
| `enable-real-ip` | `"true"` | Preserves the VPN client's real IP in access logs |

> [!NOTE]
> Because admin dashboards live in different namespaces (`monitoring`, `logging`, `tracing`, `argocd`),
> the Ingress rules use **ExternalName Services** as cross-namespace proxies. These are ClusterIP services of type `ExternalName` that resolve to the actual service DNS name in the target namespace, bypassing the namespace restriction on Ingress backends.

---

## 3. `istio.yaml` — Istio Service Mesh

**File:** [`gitops/platform/istio.yaml`](file:///c:/Users/Shivam.Gupta/OneDrive%20-%20Adastra,%20s.r.o/Desktop/Github/eks-gitops-platform/gitops/platform/istio.yaml) | **Wave 1 (CRDs) + Wave 2 (Control Plane)** | **Namespace:** `istio-system`

### Purpose
Deploys Istio to provide **mTLS encryption, sidecar proxy injection, traffic management, and telemetry** for all services in the mesh.

### Two-Component Architecture

```
Wave 1: istio-base  (CRDs)
  Registers Kubernetes CRDs:
    VirtualService, DestinationRule, Gateway,
    PeerAuthentication, AuthorizationPolicy, Telemetry, ...
  defaultRevision: ""   ← empty = non-revisioned install (stable/default channel)

Wave 2: istiod  (Control Plane)
  ├─► Sidecar injector webhook  → injects Envoy proxy into every Pod
  ├─► Certificate Authority     → issues SVID certs for mTLS
  ├─► xDS server                → pushes routing/policy config to Envoy sidecars
  └─► Telemetry v2              → generates Prometheus metrics from Envoy stats
```

#### `defaultRevision: ""` — Canary Upgrade Mechanism
In `istio-base`, setting `defaultRevision: ""` means the installation uses the **default (non-tagged) revision**. In canary upgrades you would set this to a named revision (e.g. `1-23`) so that both old and new istiod versions can coexist during a rolling migration. Leaving it empty is correct for a fresh, single-revision install.

#### `SkipDryRunOnMissingResource=true` (istiod only)
```yaml
syncOptions:
  - SkipDryRunOnMissingResource=true
```
ArgoCD performs a dry-run before applying resources to catch errors early. However, istiod references CRD types (like `Telemetry`) that **only exist after `istio-base` installs them**. Without this flag, the dry-run fails because those CRDs aren't registered yet. This flag tells ArgoCD: "if a resource type is missing at dry-run time, skip validation and apply anyway."

### Sidecar Injection
Injection is **namespace-scoped** — you opt-in per namespace:
```bash
kubectl label namespace taskmanager istio-injection=enabled
```
Once labeled, every new Pod in that namespace gets an Envoy sidecar container automatically injected before the Pod starts.

### mTLS Policy (STRICT)
Implicitly enabled globally — all pod-to-pod communication is:
- **Encrypted** (TLS 1.3)
- **Mutually authenticated** (both sides present SVID X.509 certificates)
- **Zero-trust** — a Pod cannot talk to another Pod without a valid cert

### Observability Integration

```yaml
meshConfig:
  accessLogFile: "/dev/stdout"   # Envoy access logs → stdout → Fluent Bit → Elasticsearch
  accessLogEncoding: JSON         # Structured JSON — parseable in Kibana/Grafana
  extensionProviders:
    - name: prometheus            # Envoy exposes /metrics → Prometheus scrapes
      prometheus: {}
    - name: jaeger                # Spans sent to Jaeger Collector via OTLP gRPC
      opentelemetry:
        service: jaeger-collector.tracing.svc.cluster.local
        port: 4317
  defaultProviders:
    tracing:
      - jaeger                    # ALL services in the mesh auto-generate traces
```

#### Access Logs → Fluent Bit loop
`accessLogFile: "/dev/stdout"` routes every Envoy request log to the container's stdout. From there, **Fluent Bit** (running as a DaemonSet on every node) picks them up via `/var/log/containers/*.log` and ships them to Elasticsearch — meaning **all mesh traffic is fully logged** without any application-level log instrumentation. With `accessLogEncoding: JSON`, these logs are structured and searchable in Kibana with fields like `method`, `path`, `response_code`, `upstream_cluster`.

This means:
- **Every HTTP request** between sidecar-injected pods automatically generates a distributed trace — **no application code changes needed**
- Traces appear in Jaeger UI and are **correlated to Grafana dashboards** via the pre-configured Jaeger data source
- All request access logs flow through Fluent Bit into Elasticsearch, visible in Kibana

### Telemetry v2 (Prometheus metrics)
```yaml
telemetry:
  v2:
    prometheus:
      enabled: true
```
Envoy sidecars expose enriched metrics:
- `istio_requests_total` — request counts with labels (source, destination, method, status code)
- `istio_request_duration_milliseconds` — latency histogram
- `istio_tcp_connections_opened_total` — TCP connection counts

These are scraped by Prometheus and power the default Istio dashboards in Grafana.

### Resource & Placement
| Component | Replicas | CPU | Memory | Node |
|---|---|---|---|---|
| istiod | 2 | 100m–500m | 128Mi–512Mi | system |
| Envoy sidecar | 1 per Pod | 10m–200m | 40Mi–256Mi | wherever Pod runs |

---

## 4. `monitoring.yaml` — Prometheus + Grafana Stack

**File:** [`gitops/platform/monitoring.yaml`](file:///c:/Users/Shivam.Gupta/OneDrive%20-%20Adastra,%20s.r.o/Desktop/Github/eks-gitops-platform/gitops/platform/monitoring.yaml) | **Sync Wave: 2** | **Namespace:** `monitoring`

### Purpose
Deploys the **full Kubernetes monitoring stack** using the `kube-prometheus-stack` Helm chart (the industry standard). Covers metrics collection, storage, visualization, and alerting.

### Components Deployed by this Single Chart

| Component | Role |
|---|---|
| **Prometheus Operator** | Manages `Prometheus`, `Alertmanager`, `ServiceMonitor`, `PodMonitor`, `PrometheusRule` CRDs |
| **Prometheus Server** | Scrapes and stores time-series metrics (TSDB, retained 7 days on 20Gi EBS gp3) |
| **Alertmanager** | Deduplicates, groups, and routes alerts; pre-configured for MS Teams |
| **Grafana** | Visualization dashboards — served at `/grafana` via nginx-internal |
| **Node Exporter** | DaemonSet — collects CPU, RAM, disk, network from every node |
| **kube-state-metrics** | Exposes Kubernetes object state (pod status, deployment replicas, etc.) |

### Cross-Namespace Scraping (Critical Setting)
```yaml
serviceMonitorSelectorNilUsesHelmValues: false
podMonitorSelectorNilUsesHelmValues: false
ruleSelectorNilUsesHelmValues: false
```
When set to `false`, Prometheus discovers `ServiceMonitor` and `PodMonitor` resources **in ALL namespaces**, not just the `monitoring` namespace. This is what allows KEDA, Fluent Bit, Istio, and application-level monitors to be picked up automatically.

### Dynamic App Scraping (PostgREST)
```yaml
additionalScrapeConfigs:
  - job_name: "postgrest-backend"
    kubernetes_sd_configs:
      - role: pod
        namespaces: [taskmanager]
    relabel_configs:
      - source_labels: ["__meta_kubernetes_pod_label_app"]
        action: keep
        regex: "backend"
```
Prometheus uses **Kubernetes Service Discovery** to find pods labeled `app: backend` in the `taskmanager` namespace and scrapes their `/metrics` endpoint on port 3000 — no `ServiceMonitor` CRD needed.

### Storage
| Component | Storage | StorageClass | Retention |
|---|---|---|---|
| Prometheus | 20Gi EBS gp3 | `gp3` | 7 days |
| Alertmanager | 5Gi EBS gp3 | `gp3` | 120 hours |

### Grafana Configuration
- Served at `/grafana/` subpath behind nginx-internal
- `root_url` and `serve_from_sub_path: true` ensure links/redirects work correctly
- **Pre-configured Jaeger data source** — `access: proxy` (Grafana backend proxies to Jaeger, not browser-direct), `isDefault: false` (Prometheus stays the default data source for dashboards), `nodeGraph.enabled: true` (shows the service dependency graph)
- Sidecar containers auto-load `ConfigMap`-based dashboards AND datasources from **any namespace** (`searchNamespace: ALL` on both `dashboards` and `datasources` sidecars)
- `defaultDashboardsEditable: false` — built-in dashboards are read-only; prevents accidental modification

### Alertmanager — MS Teams Routing
The full routing config present in the file:
```yaml
config:
  global:
    resolve_timeout: "5m"      # Wait 5m after alert stops firing before sending resolved
  route:
    group_by: ["alertname", "namespace", "job"]  # Group alerts by these labels
    group_wait: "30s"          # Wait 30s before sending first alert in a new group
    group_interval: "5m"       # Wait 5m before re-alerting on same group
    repeat_interval: "12h"     # Re-send unresolved alerts every 12h
    receiver: "null"           # Currently drops all alerts (stub)
  receivers:
    - name: "null"             # No-op receiver
```
Currently the receiver is `"null"` (drop all alerts — safe default during setup). To activate MS Teams:
1. Create a secret with your MS Teams webhook URL
2. Add an `msteams` receiver and update `route.receiver` to point to it

### Resource Summary
| Component | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---|---|---|---|
| Prometheus | 200m | 1000m | 512Mi | 1536Mi |
| Grafana | 100m | 500m | 128Mi | 512Mi |
| Alertmanager | 50m | 200m | 64Mi | 256Mi |

---

## 5. `efk.yaml` — EFK Logging Stack

**File:** [`gitops/platform/efk.yaml`](file:///c:/Users/Shivam.Gupta/OneDrive%20-%20Adastra,%20s.r.o/Desktop/Github/eks-gitops-platform/gitops/platform/efk.yaml) | **Wave 2 (ES) + Wave 3 (Fluent Bit & Kibana)** | **Namespace:** `logging`

### Purpose
Collects, processes, stores, and visualizes **all container logs** from every node in the cluster. Deployed as three separate ArgoCD Applications in sequence.

### Log Pipeline
```
Every Container (stdout/stderr)
  └─► /var/log/containers/*.log  (written by kubelet/CRI)
        └─► Fluent Bit DaemonSet (one pod per node)
              │  Parses CRI format, enriches with Kubernetes metadata:
              │    - pod name, namespace, labels, node name
              │  Strips noisy fields (logtag, stream)
              └─► Elasticsearch
                    └─► Index: fluent-bit-YYYY.MM.DD
                          └─► Kibana (search, dashboards, alerts)
```

### Component 1: Elasticsearch (Wave 2)

**Chart:** `elastic/elasticsearch` `8.5.1` | **Image:** `8.15.0`

| Setting | Value | Why |
|---|---|---|
| `replicas: 1` | Single node | Simplicity; scale to 3 for HA |
| `minimumMasterNodes: 1` | 1 | Required for single-node cluster |
| `esJavaOpts: -Xmx512m -Xms512m` | 512MB heap | Must be ≤ 50% of memory limit (2Gi) |
| `discovery.type: single-node` | Single-node | Disables multi-node Zen discovery |
| `xpack.security.enabled: false` | Disabled | Traffic is VPC-internal only; simplifies setup |
| `storage: 10Gi gp3` | EBS gp3 | Persistent log storage across Pod restarts |
| `nodeSelector: system` | System nodes | Pinned because it holds a large EBS volume |
| `antiAffinity: "soft"` | Soft | Kubernetes tries to spread replicas across nodes but doesn't hard-fail if it can't. Fine for single-node, essential for HA (3-replica) upgrade |

> [!WARNING]
> X-Pack security is disabled. If you open the cluster to external traffic or require compliance, enable TLS and authentication before going to production.

### Component 2: Fluent Bit (Wave 3)

**Chart:** `fluent/fluent-bit` `0.47.10` | **Kind:** DaemonSet (1 pod per node)

**Pipeline details:**

```ini
[SERVICE]
    Flush             1          # Flush buffer to ES every 1 second
    Log_Level         info
    Daemon            off        # Runs in foreground (required in containers)
    Parsers_File      /fluent-bit/etc/parsers.conf
    HTTP_Server       On         # Exposes health/metrics endpoint
    HTTP_Listen       0.0.0.0
    HTTP_Port         2020       # Scraped by Prometheus for Fluent Bit's own metrics

[INPUT]
    Name              tail
    Tag               kube.*     # All records tagged kube.* for filter matching
    Path              /var/log/containers/*.log   # All container logs
    Parser            cri        # Parse CRI container log format
    DB                /var/log/flb_kube.db        # SQLite DB — tracks last read offset (survives restarts)
    Mem_Buf_Limit     5MB        # Back-pressure protection — pause tail if buffer full
    Skip_Long_Lines   On         # Drop lines > buffer size instead of crashing
    Refresh_Interval  10         # Re-scan log directory every 10s for new container log files

[FILTER]
    Name                kubernetes # Enrich with K8s metadata
    Match               kube.*
    Kube_URL            https://kubernetes.default.svc:443
    Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
    Kube_Tag_Prefix     kube.var.log.containers.
    Merge_Log           On         # Parse JSON logs embedded in the log field
    Merge_Log_Key       log_processed  # Put parsed JSON under this key, not root level
    Keep_Log            Off        # Drop the original raw 'log' field after merging
    K8S-Logging.Parser  On         # Honor per-pod log format annotations
    K8S-Logging.Exclude On         # Honor per-pod exclude annotations
    Labels              On         # Include pod labels in each log record
    Annotations         Off        # Skip annotations (too noisy, high cardinality)

[FILTER]
    Name              modify
    Match             kube.*
    Remove            logtag     # Remove CRI-specific field (not useful in ES)
    Remove            stream     # Remove stdout/stderr field (captured via Tag)

[OUTPUT]
    Name              es
    Match             kube.*
    Host              elasticsearch-master.logging.svc.cluster.local
    Port              9200
    Logstash_Format   On         # Create daily indices: fluent-bit-YYYY.MM.DD
    Logstash_Prefix   fluent-bit # Index name: fluent-bit-YYYY.MM.DD
    Retry_Limit       False      # Infinite retries — NEVER drop a log line
    Generate_ID       On         # Deduplicate on retry (idempotent writes)
    Write_Operation   create     # create = ES rejects duplicates by ID
    Replace_Dots      On         # Dots in field names break ES mappings
    Suppress_Type_Name On        # ES 8.x dropped _type — prevents illegal_argument_exception
    tls               Off        # No TLS (VPC-internal, ES security disabled)
```

**Key settings explained:**
- **`HTTP_Server: On` / `HTTP_Port: 2020`** — Exposes Fluent Bit's built-in `/api/v1/metrics` endpoint. Prometheus can scrape this for pipeline health stats (records in/out, retries, drops).
- **`Skip_Long_Lines: On`** — Log lines longer than the input buffer are skipped rather than causing a parse failure or crash. Protects against runaway log producers.
- **`Refresh_Interval: 10`** — Fluent Bit re-scans `/var/log/containers/` every 10 seconds, picking up log files from newly started containers without delay.
- **`Merge_Log_Key: log_processed`** — When `Merge_Log: On` parses a JSON log line, the parsed fields are nested under `log_processed` instead of polluting the root record. Prevents field name collisions with Kubernetes metadata.
- **`Keep_Log: Off`** — After merging, the original raw `log` string field is dropped. Without this, you'd store both the raw string and the parsed JSON — doubling storage.
- **`Retry_Limit: False`** — Fluent Bit retries indefinitely if Elasticsearch is temporarily unavailable. This means **zero log loss** during ES restarts or upgrades, at the cost of memory buffering up to `Mem_Buf_Limit` (5MB per node).
- **`Suppress_Type_Name: On`** — Elasticsearch 8.x removed the `_type` mapping concept. Older Fluent Bit versions still include it in requests. This flag suppresses it to prevent `illegal_argument_exception` errors.
- **`Logstash_Prefix: fluent-bit`** — The full daily index name will be `fluent-bit-2024.01.15`. You can filter by date range in Kibana index patterns.

#### Custom Parsers
Fluent Bit also ships two custom parsers:
- **`cri`** — regex parser for the CRI log format: `<time> <stream> <logtag> <log>`. Extracts the timestamp in RFC3339 with nanoseconds (`%Y-%m-%dT%H:%M:%S.%L%z`).
- **`docker`** — JSON parser for legacy Docker log format with `time` key.

**Tolerations** (4 entries) allow Fluent Bit to run on **all node types** including master/control-plane nodes and any tainted spot nodes — ensuring **no logs are ever missed** regardless of node type.

### Component 3: Kibana (Wave 3)

**Chart:** `elastic/kibana` `8.5.1` | **Image:** `8.15.0`

| Setting | Value | Why |
|---|---|---|
| `elasticsearchHosts` | `http://elasticsearch-master.logging:9200` | Direct in-cluster connection, no TLS |
| `service.type: ClusterIP` | ClusterIP | Routed via nginx-internal at `/kibana/` |
| `xpack.security.enabled: false` | Disabled | Matches Elasticsearch security config |
| `telemetry.enabled: false` | Disabled | No external data sent to Elastic |
| `monitoring.ui.enabled: false` | Disabled | No X-Pack monitoring stack needed |
| `healthCheckPath: /app/kibana` | Configured | Correct liveness probe path |
| `secretMounts: []` | Empty | Explicitly disables any TLS cert secret mounts — avoids mount errors since no certs exist |

---

## 6. `tracing.yaml` — Jaeger Distributed Tracing

**File:** [`gitops/platform/tracing.yaml`](file:///c:/Users/Shivam.Gupta/OneDrive%20-%20Adastra,%20s.r.o/Desktop/Github/eks-gitops-platform/gitops/platform/tracing.yaml) | **Sync Wave: 3** | **Namespace:** `tracing`

### Purpose
Deploys **Jaeger** for end-to-end distributed tracing. Collects spans from Istio's automatic trace generation AND from application-level OTLP instrumentation.

### Architecture
```
Istio Envoy sidecar (auto)
  └─► OTLP gRPC (port 4317) ──┐
                                 ├─► Jaeger Collector
App SDK (manual instrumentation) ─┘      └─► Elasticsearch (logging namespace)
  └─► OTLP HTTP (port 4318) ──┘                └─► fluent-bit-* index pattern

Jaeger Query UI ────────────────────────────────► /jaeger (nginx-internal)
                                                    └─► Grafana data source
```

### Component Breakdown

#### Jaeger Query (UI)
- Serves the trace search UI at `/jaeger` (base-path configured with `--query.base-path=/jaeger`)
- Type: `ClusterIP` — exposed via nginx-internal Ingress
- Access: `http://<internal-nlb-ip>/jaeger` (requires VPN/SSM)

#### Jaeger Collector (Span Ingestion)
- Accepts spans from two protocols:
  - **OTLP gRPC** on port `4317` — used by Istio (`istiod` config in `istio.yaml`)
  - **OTLP HTTP** on port `4318` — used by application SDKs
- Application env var for instrumentation:
  ```bash
  OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger-collector.tracing.svc.cluster.local:4318
  ```

#### Jaeger Agent
- Enabled as a sidecar/DaemonSet (depending on chart version) for legacy Thrift protocol support

#### Storage
```yaml
storage:
  type: elasticsearch
  elasticsearch:
    host: "elasticsearch-master.logging.svc.cluster.local"
    port: 9200
```
**Reuses the same Elasticsearch cluster** deployed by `efk.yaml` — saves resources. Trace data is stored in ES indices alongside log data.

### Grafana Integration
Jaeger is pre-configured as a data source in `monitoring.yaml`:
```yaml
additionalDataSources:
  - name: Jaeger
    type: jaeger
    url: "http://jaeger-query.tracing.svc.cluster.local:16686/jaeger"
    jsonData:
      nodeGraph:
        enabled: true    # Shows service dependency graph
```
This enables **trace → log correlation** directly in Grafana dashboards.

---

## 7. `keda.yaml` — KEDA + Metrics Server

**File:** [`gitops/platform/keda.yaml`](file:///c:/Users/Shivam.Gupta/OneDrive%20-%20Adastra,%20s.r.o/Desktop/Github/eks-gitops-platform/gitops/platform/keda.yaml) | **Wave 1 (Metrics Server) + Wave 2 (KEDA)** | **Namespaces:** `kube-system` / `keda`

### Purpose
Provides **two layers of autoscaling**:
1. **Metrics Server** — CPU/Memory data for standard Kubernetes HPA
2. **KEDA** — Event-driven scaling based on external signals (Prometheus metrics, SQS queues, etc.)

### Component 1: Metrics Server (Wave 1)

**Chart:** `metrics-server` `3.12.1` | **Namespace:** `kube-system`

- Exposes the `/apis/metrics.k8s.io` API that Kubernetes HPA reads
- **Must live in `kube-system`** — the Kubernetes API server is hardcoded to look there
- `--kubelet-insecure-tls` flag: Required on EKS because kubelet uses self-signed certificates that can't be validated without custom CA configuration

### Component 2: KEDA Controller (Wave 2)

**Chart:** `keda` `2.15.1` | **Namespace:** `keda`

#### How KEDA Works
```
ScaledObject (Custom Resource)
  └─► KEDA Controller watches it
        └─► Reads the trigger (Prometheus query / SQS depth / etc.)
              └─► Adjusts HPA targetReplicas dynamically
                    └─► HPA scales the Deployment
```

#### Example ScaledObject for Prometheus-based scaling
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: backend-scaler
  namespace: taskmanager
spec:
  scaleTargetRef:
    name: backend
  minReplicaCount: 1
  maxReplicaCount: 10
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://kube-prometheus-stack-prometheus.monitoring:9090
        metricName: http_requests_total
        threshold: "100"
        query: sum(rate(istio_requests_total{destination_app="backend"}[2m]))
```

#### Key KEDA Settings

| Setting | Value | Why |
|---|---|---|
| `replicaCount: 2` | 2 | HA — KEDA itself uses leader election |
| `nodeSelector: system` | System nodes | Control plane components run on stable on-demand nodes |
| `prometheus.operator.enabled: true` | Enabled | KEDA exposes its own metrics for Prometheus to scrape |
| `prometheus.operator.port` | `8080` | Port on which KEDA exposes its metrics endpoint |
| `serviceMonitor.enabled: true` | Enabled | Creates a `ServiceMonitor` CRD so Prometheus auto-discovers KEDA |
| `serviceMonitor.namespace: monitoring` | `monitoring` | ServiceMonitor is created in the monitoring namespace where Prometheus runs |

#### KEDA Resource Split — `operator` vs `metricServer`
KEDA runs **two separate processes**, each with its own resource limits:
```yaml
resources:
  operator:          # The main KEDA controller — watches ScaledObjects, adjusts HPA
    requests: { cpu: "50m", memory: "64Mi" }
    limits:   { cpu: "200m", memory: "256Mi" }
  metricServer:      # Serves custom metrics API — HPA queries this to get scaler values
    requests: { cpu: "50m", memory: "64Mi" }
    limits:   { cpu: "200m", memory: "256Mi" }
```
The `metricServer` implements the Kubernetes [External Metrics API](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#support-for-metrics-apis) (`external.metrics.k8s.io`). The HPA controller queries it to get the current scaler value (e.g. queue depth) before deciding whether to scale.

#### KEDA's Own Metrics (Self-observability)
KEDA exposes scaling decisions and queue depths on port `8080`. Prometheus scrapes this via the `ServiceMonitor` KEDA creates in the `monitoring` namespace. This lets you:
- See scaling decisions in Grafana
- Alert on scaling failures or stuck queues

---

## Sync Wave Execution Order

The complete ordered startup sequence across all platform files:

```
Wave 1 (Foundations):
  ├─► ingress-nginx-public   (ingress-public.yaml)
  ├─► ingress-nginx-internal (ingress-internal.yaml)
  ├─► istio-base             (istio.yaml — CRDs only)
  └─► metrics-server         (keda.yaml)

Wave 2 (Core Services):
  ├─► istiod                 (istio.yaml — control plane)
  ├─► kube-prometheus-stack  (monitoring.yaml)
  ├─► efk-elasticsearch      (efk.yaml)
  └─► keda                   (keda.yaml)

Wave 3 (Depends on Wave 2):
  ├─► efk-fluent-bit         (efk.yaml — needs Elasticsearch)
  ├─► efk-kibana             (efk.yaml — needs Elasticsearch)
  └─► jaeger                 (tracing.yaml — needs Elasticsearch)
```

> [!NOTE]
> Wave numbers are **per-file** (each file's ArgoCD Applications set their own waves). ArgoCD processes waves in ascending numeric order within a sync operation.

---

## Node Placement Strategy

All stateful and control-plane components are pinned to `nodegroup: system` (on-demand nodes):

| Component | Runs On | Why |
|---|---|---|
| Prometheus | system | Holds a 20Gi EBS volume |
| Alertmanager | system | Holds a 5Gi EBS volume |
| Elasticsearch | system | Holds a 10Gi EBS volume |
| Grafana | system | Stable availability for dashboards |
| Kibana | system | Stable availability for dashboards |
| Jaeger Query | system | Stable availability for tracing UI |
| Jaeger Collector | system | Stable span ingestion (can't lose traces) |
| istiod | system | Control plane — must be stable |
| nginx-public | system | Traffic entry point |
| nginx-internal | system | Admin access entry point |
| KEDA | system | Autoscaling control plane |
| Metrics Server | system | HPA dependency |
| **Fluent Bit** | **ALL nodes** | DaemonSet — must collect logs from every node |
| **node-exporter** | **ALL nodes** | DaemonSet — must collect metrics from every node |
| **Envoy sidecars** | **wherever app runs** | Injected into app pods by istiod |

---

## Overall Observability Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                          Application Pod                         │
│  ┌────────────┐   stdout    ┌─────────────────┐                 │
│  │ App Container│──────────►│  Envoy Sidecar  │                 │
│  └────────────┘             │  (injected by   │                 │
│                             │    istiod)      │                 │
└─────────────────────────────│─────────────────│─────────────────┘
                              │                 │
              ┌───────────────┤                 ├─────────────────┐
              │               │                 │                 │
              ▼               ▼                 ▼                 │
    /var/log/containers/   Prometheus        OTLP gRPC            │
              │            /metrics          (4317)               │
              ▼               │                 │                 │
       Fluent Bit          Prometheus        Jaeger               │
      (DaemonSet)          Server          Collector              │
              │               │                 │                 │
              ▼               ▼                 ▼                 │
       Elasticsearch      TSDB (EBS)      Elasticsearch           │
       (logging NS)      (20Gi gp3)       (logging NS)            │
              │               │                 │                 │
              └───────┬───────┘                 │                 │
                      ▼                         ▼                 │
                   Grafana ◄─────────── Jaeger Query UI           │
                  /grafana/                 /jaeger/               │
                      ▼                                           │
                   Kibana                                          │
                  /kibana/                                         │
                                                                   │
              All above served via nginx-internal NLB ◄───────────┘
              (VPC-only, requires VPN or SSM)
```
