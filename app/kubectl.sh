# Connect / Update kubeconfig for your EKS cluster
aws eks update-kubeconfig --region us-east-1 --name <cluster_name>

# View current context and cluster info
kubectl config current-context
kubectl cluster-info

# Switch namespace for all subsequent commands (avoids typing -n <ns> every time)
kubectl config set-context --current --namespace=taskmanager

# List all pods across ALL namespaces with Node and IP details
kubectl get pods -A -o wide

# Watch pods in real-time (useful during deployments)
kubectl get pods -n taskmanager -w

# Find pods that are NOT in 'Running' status (CrashLoopBackOff, Error, Pending)
kubectl get pods -A --field-selector=status.phase!=Running

# Sort pods by restart count (find unstable pods quickly)
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount'

# Inspect full pod definition, events, and failure reasons
kubectl describe pod <pod_name> -n <namespace>

# Stream live logs from a pod
kubectl logs -f <pod_name> -n <namespace>

# Stream logs from a specific container in a multi-container pod (e.g., Istio sidecar)
kubectl logs -f <pod_name> -c <container_name> -n <namespace>

# View logs from a PREVIOUS crashed container instance (crucial for CrashLoopBackOff)
kubectl logs <pod_name> --previous -n <namespace>

# Stream logs from ALL pods with a specific label
kubectl logs -f -l app=backend -n taskmanager --tail=100

# Open an interactive bash/sh shell inside a running pod
kubectl exec -it <pod_name> -n <namespace> -- /bin/sh

# Forward a local port directly to a pod or service (no Ingress/NLB required)
kubectl port-forward svc/taskmanager-backend 8080:8080 -n taskmanager

# Check deployment rollout progress
kubectl rollout status deployment/taskmanager-backend -n taskmanager

# View deployment rollout revision history
kubectl rollout history deployment/taskmanager-backend -n taskmanager

# Trigger a zero-downtime rolling restart (re-pulls secrets & configs)
kubectl rollout restart deployment/taskmanager-backend -n taskmanager

# Roll back to the previous deployment revision
kubectl rollout undo deployment/taskmanager-backend -n taskmanager

# Roll back to a specific revision number
kubectl rollout undo deployment/taskmanager-backend --to-revision=2 -n taskmanager

# Scale deployment replicas manually
kubectl scale deployment/taskmanager-backend --replicas=5 -n taskmanager

# List all Services with their ClusterIP, NodePort, and LoadBalancer DNS/IP
kubectl get svc -A

# List all Ingress objects and their host rules
kubectl get ingress -A

# Check endpoints behind a service (verify if pods are attached to the service)
kubectl get endpoints <service_name> -n <namespace>

# Check CPU & Memory usage across all worker nodes (requires Metrics Server)
kubectl top nodes

# Check CPU & Memory usage across pods in a namespace
kubectl top pods -n taskmanager --sort-by=memory

# View node labels and instance types (useful for Karpenter/Graviton audit)
kubectl get nodes -L node.kubernetes.io/instance-type,karpenter.sh/capacity-type,kubernetes.io/arch

# Safely drain a node for maintenance (evicts pods gracefully respecting PDB)
kubectl cordon <node_name>                     # Mark node unschedulable
kubectl drain <node_name> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node_name>                   # Re-enable scheduling

# List persistent volume claims (PVCs) and their bound status
kubectl get pvc -A

# View and decode a Kubernetes Secret in base64 to plain text
kubectl get secret <secret_name> -n <namespace> -o jsonpath="{.data.<key_name>}" | base64 --decode

# View all ConfigMaps in a namespace
kubectl get configmap -n taskmanager

# ArgoCD: List all applications and their health/sync status
kubectl get applications -n argocd

# Karpenter: List dynamic NodePools and NodeClaims
kubectl get nodepools
kubectl get nodeclaims

# Prometheus Operator: List active alerting rules
kubectl get prometheusrules -A

# Istio: List virtual services and gateways
kubectl get virtualservices,gateways -A

# KEDA: List ScaledObjects and trigger states
kubectl get scaledobjects -A

# 1. Force-delete a stuck terminating pod immediately
kubectl delete pod <pod_name> -n <namespace> --grace-period=0 --force

# 2. Extract all OOMKilled pods across the entire cluster
kubectl get pods -A -o json | jq -r '.items[] | select(.status.containerStatuses[]?.lastState.terminated.reason=="OOMKilled") | "\(.metadata.namespace)/\(.metadata.name)"'

# 3. Find which node a specific pod is running on
kubectl get pod <pod_name> -n <namespace> -o jsonpath='{.spec.nodeName}'

# 4. View Kubernetes cluster warning events sorted by time
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp'

