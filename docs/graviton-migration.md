# Graviton (ARM64) Migration Runbook
### Zero-Downtime EKS Migration — `eks-gitops-platform`

> **Goal:** Migrate all EC2 nodes (managed node groups + Karpenter-provisioned) from `x86_64` (Intel/AMD)
> to `arm64` (AWS Graviton) with **no application downtime** and a clear rollback path at every phase.

---

## Table of Contents

1. [Architecture Overview — Before & After](#architecture-overview--before--after)
2. [Pre-Flight Checklist](#pre-flight-checklist)
3. [Phase 1 — Multi-Arch Docker Images](#phase-1--multi-arch-docker-images)
4. [Phase 2 — Karpenter NodePool Dual-Arch](#phase-2--karpenter-nodepool-dual-arch-transition)
5. [Phase 3a — Migrate `app_nodes` (Stateless SPOT)](#phase-3a--migrate-app_nodes-stateless-spot)
6. [Phase 3b — Migrate `system_nodes` (Stateful ON_DEMAND)](#phase-3b--migrate-system_nodes-stateful-on_demand)
7. [Phase 4 — Graviton-Only Lock-In](#phase-4--graviton-only-lock-in)
8. [Validation Checklist](#validation-checklist)
9. [Rollback Runbook](#rollback-runbook)
10. [Cost Savings Estimate](#cost-savings-estimate)

---

## Architecture Overview — Before & After

### Current State

| Node Group | File | AMI | Instance | Capacity | Workloads |
|---|---|---|---|---|---|
| `system_nodes` | `terraform/eks.tf` | `AL2_x86_64` | `t3.medium` (var) | ON_DEMAND | ArgoCD, Monitoring, EFK, Istio, Ingress |
| `app_nodes` | `terraform/eks.tf` | `AL2_x86_64` | `t3.small` (var) | SPOT | Frontend (Nginx), Backend (PostgREST) |
| Karpenter pool | `k8s/karpenter-nodepool.yaml` | `AL2023` | `t3/t3a/c6i/c5/m6i/m5` | Spot + OD | Dynamic app scaling |

### Target State

| Node Group | File | AMI | Instance | Capacity | Workloads |
|---|---|---|---|---|---|
| `system_nodes` | `terraform/eks.tf` | `AL2023_ARM_64` | `m7g.medium` | ON_DEMAND | ArgoCD, Monitoring, EFK, Istio, Ingress |
| `app_nodes` | `terraform/eks.tf` | `AL2023_ARM_64` | `t4g.small` | SPOT | Frontend (Nginx), Backend (PostgREST) |
| Karpenter pool | `k8s/karpenter-nodepool.yaml` | `AL2023` | `t4g/c7g/m7g/c6g/m6g` | Spot + OD | Dynamic app scaling |

### Migration Phases — Safe Order

```
Phase 1: Multi-arch images   →  Zero risk (CI/CD change only)
Phase 2: Karpenter dual-arch →  Zero risk (additive, old nodes untouched)
Phase 3a: app_nodes          →  Low risk  (stateless SPOT pods)
Phase 3b: system_nodes       →  Medium    (stateful PVCs — follow carefully)
Phase 4: Graviton-only       →  Cleanup   (remove x86 from NodePool)
```

> [!IMPORTANT]
> **Do NOT skip Phase 1.** If your container images don't have an `arm64` manifest,
> pods will be stuck in `ImagePullBackOff` on Graviton nodes. There is no Kubernetes-level
> fallback for architecture mismatch.

---

## Pre-Flight Checklist

Run these checks before starting any phase:

### 1. Verify container image architectures

```bash
# Check official images used in this repo
docker buildx imagetools inspect postgrest/postgrest:v12.2.3 | grep -A2 "Platform"
docker buildx imagetools inspect nginx:1.25-alpine | grep -A2 "Platform"

# Both should show:
# Platform:    linux/amd64
# Platform:    linux/arm64   <- required
```

> [!NOTE]
> `postgrest/postgrest` and `nginx:1.25-alpine` are official multi-arch images — already safe.
> For any **custom-built** images (Spring Boot backend), follow Phase 1.

### 2. Check your Kubernetes version supports AL2023_ARM_64

```bash
kubectl version --short
# Requires: >= 1.29 for full AL2023 ARM support (this repo uses 1.30 - OK)
```

### 3. Note your RDS instance class

```
Your RDS is already: db.t4g.micro (Graviton2)
No RDS migration needed.
```

### 4. Record current node state (save as baseline)

```bash
kubectl get nodes -o wide > /tmp/nodes-before-migration.txt
kubectl get pods -A -o wide > /tmp/pods-before-migration.txt

# Note Karpenter-managed nodes
kubectl get nodes -l karpenter.sh/nodepool=app-nodepool -o wide
```

### 5. Confirm PVC AZs (critical for Phase 3b)

```bash
kubectl get pvc -A
kubectl get pv -o custom-columns=NAME:.metadata.name,AZ:.metadata.labels."topology\.kubernetes\.io/zone",SIZE:.spec.capacity.storage
```

> [!WARNING]
> EBS volumes are AZ-locked. When you migrate `system_nodes`, the new Graviton node
> **must come up in the same AZ** as the existing PVCs. Confirm this in Phase 3b before draining.

---

## Phase 1 — Multi-Arch Docker Images

**Risk:** None — CI/CD pipeline change only. No cluster impact.

**File:** [`app/backend-cicd.yml`](../app/backend-cicd.yml)

### Change Required

The current `build-image` job builds single-arch only:

```yaml
# CURRENT — single arch (x86 only)
- name: Build backend image
  run: |
    docker build \
      -f Dockerfile.backend \
      -t ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.meta.outputs.tag }} \
      ./app/
```

Replace with `docker buildx` for multi-arch output:

```yaml
# NEW — multi-arch (amd64 + arm64)
- name: Set up Docker Buildx
  uses: docker/setup-buildx-action@v3
  with:
    platforms: linux/amd64,linux/arm64

- name: Set up QEMU (ARM emulation for cross-compile)
  uses: docker/setup-qemu-action@v3

- name: Build and push multi-arch image
  uses: docker/build-push-action@v5
  with:
    context: ./app/
    file: ./app/Dockerfile.backend
    platforms: linux/amd64,linux/arm64
    push: true
    tags: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.meta.outputs.tag }}
```

### Validate

```bash
# After CI runs, verify the manifest includes arm64
docker buildx imagetools inspect ghcr.io/<your-org>/<your-repo>-backend:<sha>

# Expected output:
# Platform:    linux/amd64
# Platform:    linux/arm64  <- must be present
```

### Rollback — Phase 1

Revert `backend-cicd.yml` to the single-arch `docker build` command. No cluster impact at all.

---

## Phase 2 — Karpenter NodePool Dual-Arch Transition

**Risk:** Zero — purely additive. Existing `amd64` nodes are untouched.
New workloads may land on Graviton, which is safe once Phase 1 is complete.

**File:** [`k8s/karpenter-nodepool.yaml`](../k8s/karpenter-nodepool.yaml)

### Change Required

```yaml
# CURRENT
requirements:
  - key: kubernetes.io/arch
    operator: In
    values: ["amd64"]

  - key: node.kubernetes.io/instance-type
    operator: In
    values:
      - t3.small
      - t3.medium
      - t3a.small
      - t3a.medium
      - c6i.large
      - c5.large
      - m6i.large
      - m5.large
```

```yaml
# NEW — dual-arch during transition
requirements:
  - key: kubernetes.io/arch
    operator: In
    values: ["amd64", "arm64"]   # allow both architectures

  - key: node.kubernetes.io/instance-type
    operator: In
    values:
      # x86 — kept as fallback during transition
      - t3.small
      - t3.medium
      - t3a.small
      - t3a.medium
      - c6i.large
      - m6i.large
      # Graviton — added (~20-40% cheaper, better perf/$)
      - t4g.small         # Graviton2 burstable <- replaces t3.small
      - t4g.medium        # Graviton2 burstable <- replaces t3.medium
      - c7g.large         # Graviton3 compute   <- replaces c6i.large
      - m7g.large         # Graviton3 balanced  <- replaces m6i.large
      - c6g.large         # Graviton2 fallback
      - m6g.large         # Graviton2 fallback
```

### Apply

```bash
# Push to main — ArgoCD auto-applies via the platform-apps root Application
git add k8s/karpenter-nodepool.yaml
git commit -m "feat: add arm64 Graviton instances to Karpenter NodePool"
git push origin main

# Or apply directly for immediate effect
kubectl apply -f k8s/karpenter-nodepool.yaml

# Monitor Karpenter provisioning decisions
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --follow | grep -i "launched\|arm64\|graviton"
```

### Validate

```bash
# Watch for new arm64 nodes appearing
kubectl get nodes -L kubernetes.io/arch -w

# Check Karpenter is choosing Graviton for new pending pods
kubectl get nodeclaim -o wide
```

### Rollback — Phase 2

```bash
# Revert arch requirement to amd64 only and remove Graviton instance types
kubectl apply -f k8s/karpenter-nodepool.yaml   # with reverted values

# Karpenter automatically drains Graviton nodes it launched
# and reschedules pods to x86 nodes
```

---

## Phase 3a — Migrate `app_nodes` (Stateless SPOT)

**Risk:** Low — pods are stateless (Nginx + PostgREST). They restart instantly.
The managed node group rolling update replaces nodes one at a time.

**Files:** [`terraform/eks.tf`](../terraform/eks.tf), [`terraform/variables.tf`](../terraform/variables.tf)

### Change Required

**Option A — via `variables.tf` defaults (recommended):**

```hcl
# terraform/variables.tf
variable "app_node_instance_type" {
  default = "t4g.small"    # was: "t3.small"
}
```

**Option B — directly in `eks.tf`:**

```hcl
# terraform/eks.tf — app_nodes block
app_nodes = {
  ami_type       = "AL2023_ARM_64"   # was: AL2_x86_64
  instance_types = ["t4g.small"]     # Graviton2 equivalent of t3.small
  capacity_type  = var.app_node_capacity_type
  min_size       = var.app_node_min_size
  max_size       = var.app_node_max_size
  desired_size   = var.app_node_desired_size
  subnet_ids     = module.vpc.private_subnets
  disk_size      = 20
  labels = {
    role      = "application"
    nodegroup = "app"
  }
}
```

### Apply

```bash
# Preview changes — confirm only app_nodes AMI type changes
terraform plan -target=module.eks

# Apply — AWS replaces nodes via rolling update (max_unavailable = 1 by default)
terraform apply -target=module.eks
```

### What Happens Internally

```
AWS creates a new launch template (AL2023_ARM_64 AMI)
  └─► Starts 1 new t4g.small Graviton node
        └─► New node joins cluster, becomes Ready
              └─► Old t3.small node is cordoned and drained
                    └─► frontend + backend pods reschedule to new Graviton node
                          └─► Old node terminated
                                └─► Repeat for remaining nodes
```

### Monitor the Rolling Update

```bash
# Watch nodes replace one at a time
kubectl get nodes -L kubernetes.io/arch -w

# Watch pods reschedule
kubectl get pods -n taskmanager -o wide -w

# Confirm no downtime — backend should keep responding
watch -n 5 "curl -s http://<public-nlb-hostname>/api/"
```

### Rollback — Phase 3a

```hcl
# terraform/variables.tf: app_node_instance_type = "t3.small"
# terraform/eks.tf:       ami_type = "AL2_x86_64"
```

```bash
terraform apply -target=module.eks
# Same rolling update — AWS replaces back to x86 one at a time
```

---

## Phase 3b — Migrate `system_nodes` (Stateful ON_DEMAND)

**Risk:** Medium — these nodes hold EBS PVCs (Prometheus 20Gi, Elasticsearch 10Gi, Alertmanager 5Gi).
Follow the **manual drain procedure** — do not rely purely on Terraform rolling update.

> [!CAUTION]
> EBS volumes are AZ-locked. If a new Graviton node launches in a **different AZ** from the PVC,
> the StatefulSet pod will be stuck `Pending` because the volume cannot attach cross-AZ.
> Always verify AZ alignment before draining.

**File:** [`terraform/eks.tf`](../terraform/eks.tf)

### Step 1 — Temporarily scale up system_nodes by 1

```hcl
# terraform/variables.tf
variable "system_node_desired_size" {
  default = 3    # was: 2 — add 1 extra Graviton node before draining x86
}
variable "system_node_max_size" {
  default = 4    # temporarily expand ceiling
}
```

Apply only the scaling change first (keep ami_type as AL2_x86_64 for now):

```bash
terraform apply -target=module.eks
kubectl get nodes -w   # wait for 3rd node to become Ready
```

### Step 2 — Change AMI type for system_nodes

```hcl
# terraform/eks.tf — system_nodes block
system_nodes = {
  ami_type       = "AL2023_ARM_64"   # was: AL2_x86_64
  instance_types = ["m7g.medium"]    # Graviton3 equivalent of t3.medium
  capacity_type  = var.system_node_capacity_type
  min_size       = var.system_node_min_size
  max_size       = 4                 # temporarily expanded
  desired_size   = 3                 # temporarily expanded
  subnet_ids     = module.vpc.private_subnets
  disk_size      = 20
  labels = {
    role      = "system"
    nodegroup = "system"
  }
}
```

```bash
terraform apply -target=module.eks
# This creates a NEW Graviton node while old x86 nodes keep running
kubectl get nodes -L kubernetes.io/arch,topology.kubernetes.io/zone
```

### Step 3 — Verify AZ alignment BEFORE draining

```bash
# Get AZ of each PVC's bound PV
kubectl get pv -o custom-columns=\
"NAME:.metadata.name,\
AZ:.metadata.labels.topology\.kubernetes\.io/zone,\
SIZE:.spec.capacity.storage,\
CLAIM:.spec.claimRef.name"

# Get AZ of the new Graviton node
kubectl get nodes -L kubernetes.io/arch,topology.kubernetes.io/zone | grep arm64

# Only proceed if Graviton node AZ matches PVC AZs
# If they differ, terminate the Graviton node and let AWS retry
```

### Step 4 — Manually drain one x86 node at a time

```bash
# List x86 system nodes
kubectl get nodes -L kubernetes.io/arch | grep amd64

# Cordon first x86 node (stop new pods landing here)
kubectl cordon <x86-system-node-1>

# Drain it — StatefulSet pods (Prometheus, Elasticsearch) re-attach PVCs on new node
kubectl drain <x86-system-node-1> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=300s

# Watch pods recover on Graviton node (StatefulSet re-schedules in order)
kubectl get pods -n monitoring -o wide -w
kubectl get pods -n logging -o wide -w
kubectl get pods -n tracing -o wide -w
```

### Step 5 — Validate services BEFORE draining the next node

```bash
# Prometheus
kubectl exec -n monitoring \
  $(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}') \
  -- wget -qO- localhost:9090/-/healthy
# Expected: Prometheus is Healthy

# Elasticsearch
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s localhost:9200/_cluster/health | python3 -m json.tool | grep status
# Expected: "green"

# Grafana pod on Graviton
kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o wide
# Should show arm64 node in NODE column
```

### Step 6 — Drain remaining x86 nodes then scale back down

```bash
# Repeat Step 4 for each remaining x86 node
kubectl cordon <x86-system-node-2>
kubectl drain <x86-system-node-2> --ignore-daemonsets --delete-emptydir-data --timeout=300s

# Scale back to normal desired size after all x86 nodes are drained
# terraform/variables.tf:
#   system_node_desired_size = 2
#   system_node_max_size     = 3
terraform apply -target=module.eks
# AWS terminates the excess drained x86 node automatically
```

### Rollback — Phase 3b

```bash
# Option A — if Graviton node not yet draining x86:
# Simply revert eks.tf to AL2_x86_64 + t3.medium and re-apply
terraform apply -target=module.eks

# Option B — if Graviton node is running and pods are stuck:

# 1. Uncordon the old x86 node immediately (if not yet terminated)
kubectl uncordon <x86-system-node>

# 2. Delete the Graviton node to force pods back to x86
kubectl delete node <graviton-node>

# 3. Revert eks.tf ami_type
# system_nodes: ami_type = "AL2_x86_64", instance_types = ["t3.medium"]
terraform apply -target=module.eks

# 4. If a StatefulSet pod is stuck Pending (PVC attach failure):
kubectl describe pod <stuck-pod> -n monitoring   # check Events
kubectl delete pod <stuck-pod> -n monitoring --grace-period=0 --force
```

---

## Phase 4 — Graviton-Only Lock-In

**Run only after all managed node groups are confirmed stable on Graviton.**

**File:** [`k8s/karpenter-nodepool.yaml`](../k8s/karpenter-nodepool.yaml)

### Change Required

```yaml
requirements:
  - key: kubernetes.io/arch
    operator: In
    values: ["arm64"]       # Remove "amd64"

  - key: node.kubernetes.io/instance-type
    operator: In
    values:
      # Graviton only — all x86 instance types removed
      - t4g.small
      - t4g.medium
      - c7g.large
      - m7g.large
      - c6g.large
      - m6g.large
```

### Apply & Validate

```bash
git add k8s/karpenter-nodepool.yaml
git commit -m "feat: lock Karpenter NodePool to arm64 Graviton only"
git push origin main

# Confirm no x86 Karpenter nodes remain
kubectl get nodes -L kubernetes.io/arch | grep amd64
# Expected: no output
```

### Rollback — Phase 4

```bash
# Add "amd64" back to arch values and x86 instance types
git revert HEAD
git push origin main
# ArgoCD re-applies within 3 minutes
```

---

## Validation Checklist

Run all commands after completing the full migration:

```bash
# 1. All nodes are arm64
kubectl get nodes -L kubernetes.io/arch
# Expected: arm64 for ALL nodes

# 2. No pods stuck
kubectl get pods -A | grep -v -E "Running|Completed"
# Expected: empty

# 3. Prometheus healthy
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 &
curl -s http://localhost:9090/-/healthy
# Expected: Prometheus is Healthy

# 4. Grafana healthy
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80 &
curl -s http://localhost:3000/api/health
# Expected: {"database":"ok"}

# 5. Elasticsearch green
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s http://localhost:9200/_cluster/health | python3 -m json.tool | grep '"status"'
# Expected: "green"

# 6. Fluent Bit shipping logs
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s "http://localhost:9200/_cat/indices?v&h=index,docs.count" | grep fluent-bit
# Expected: today's index with doc count > 0

# 7. Application endpoints
curl -s http://<public-nlb-hostname>/        # Frontend
curl -s http://<public-nlb-hostname>/api/    # PostgREST backend

# 8. Karpenter only provisioning Graviton
kubectl get nodeclaim
# All NodeClaims should reference t4g/c7g/m7g instance types

# 9. No x86 nodes remaining anywhere
kubectl get nodes -L kubernetes.io/arch | grep amd64
# Expected: empty
```

---

## Rollback Runbook

### Quick Reference

| Phase | Rollback Action | Time to Recover |
|---|---|---|
| **Phase 1** — CI/CD images | Revert `backend-cicd.yml` to single-arch `docker build` | ~5 min (next CI run) |
| **Phase 2** — Karpenter dual-arch | Revert `karpenter-nodepool.yaml` to `amd64` only | ~2 min (ArgoCD sync) |
| **Phase 3a** — app_nodes | Set `ami_type = AL2_x86_64` + `t3.small` + `terraform apply` | ~10 min (rolling update) |
| **Phase 3b** — system_nodes | Uncordon x86 + delete Graviton node + revert Terraform | ~5 min + pod restart |
| **Phase 4** — lock-in | `git revert` + push — ArgoCD re-applies | ~3 min |

---

### Emergency: Pod Stuck `ImagePullBackOff` on Graviton Node

```bash
# Symptom: image has no arm64 manifest
kubectl describe pod <pod-name> -n <namespace> | tail -20
# Look for: "no matching manifest for linux/arm64"

# Immediate — cordon the Graviton node
kubectl cordon <graviton-node>

# Immediate — delete pod; it reschedules to an x86 node
kubectl delete pod <pod-name> -n <namespace>

# Root fix — complete Phase 1 to build multi-arch image, then uncordon
kubectl uncordon <graviton-node>
```

---

### Emergency: StatefulSet Stuck `Pending` — PVC Cannot Attach

```bash
# Symptom: Prometheus or Elasticsearch pod Pending after Phase 3b
kubectl describe pod <pod-name> -n <namespace> | grep -A5 Events
# Look for:
#   "Volume is already exclusively attached to one node"
#   "node had no available volume zone"

# Fix 1 — check which node holds the volume attachment
kubectl get volumeattachments | grep <pv-name>

# Fix 2 — force detach the VolumeAttachment (use carefully)
kubectl delete volumeattachment <attachment-name>

# Fix 3 — if cross-AZ mismatch: delete Graviton node, AWS retries in correct AZ
kubectl delete node <graviton-node>

# Fix 4 — force delete the stuck pod to trigger re-scheduling
kubectl delete pod <pod-name> -n <namespace> --grace-period=0 --force
```

---

### Emergency: Full Rollback — All Phases

```bash
# Step 1 — Revert Karpenter NodePool to x86 only
git revert <phase-2-commit-sha>
git push origin main
# Wait for ArgoCD sync (~2 min)

# Step 2 — Revert Terraform node groups to x86
# eks.tf: ami_type = "AL2_x86_64" for both groups
# variables.tf: system_node_instance_type = "t3.medium", app_node_instance_type = "t3.small"
terraform apply -target=module.eks

# Step 3 — Revert CI/CD image builds
git revert <phase-1-commit-sha>
git push origin main

# Step 4 — Final verification
kubectl get nodes -L kubernetes.io/arch
# Expected: amd64 for all nodes

kubectl get pods -A | grep -v -E "Running|Completed"
# Expected: empty
```

---

## Cost Savings Estimate

Based on `us-east-1` pricing (Spot provides an additional ~60-70% saving on top):

| Current x86 | Graviton Equivalent | Savings |
|---|---|---|
| `t3.medium` → `t4g.medium` | 2 vCPU, 4GB | **~19%** cheaper |
| `t3.small` → `t4g.small` | 2 vCPU, 2GB | **~19%** cheaper |
| `c6i.large` → `c7g.large` | 2 vCPU, 4GB | **~15%** cheaper + 30% faster |
| `m6i.large` → `m7g.large` | 2 vCPU, 8GB | **~15%** cheaper + 30% faster |

**For this repo's typical workload (2 system + 2 app nodes):**

| Scenario | Monthly Estimate |
|---|---|
| Current x86 ON_DEMAND | ~$120/month |
| Graviton ON_DEMAND | ~$96/month |
| **Graviton Spot** | **~$29/month** |

> [!TIP]
> Graviton Spot capacity in `us-east-1` tends to be **more available** than equivalent x86 Spot
> because it's a newer fleet with less competition. Once Graviton instance types are in your
> Karpenter NodePool, Karpenter naturally prefers them when Graviton Spot bids are cheaper.

---

## Related Files

| File | Purpose | Changed in Phase |
|---|---|---|
| [`k8s/karpenter-nodepool.yaml`](../k8s/karpenter-nodepool.yaml) | Karpenter instance requirements | 2, 4 |
| [`terraform/eks.tf`](../terraform/eks.tf) | Managed node group AMI and instance type | 3a, 3b |
| [`terraform/variables.tf`](../terraform/variables.tf) | Instance type and size variable defaults | 3a, 3b |
| [`app/backend-cicd.yml`](../app/backend-cicd.yml) | Docker image build pipeline | 1 |
| [`terraform/storage.tf`](../terraform/storage.tf) | EBS gp3 StorageClass — no change needed | — |
