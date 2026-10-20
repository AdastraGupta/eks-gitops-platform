#!/usr/bin/env bash
# ─── Linux & DevOps Troubleshooting Cheatsheet ────────────────────────────────
# Useful command one-liners for log analysis, debugging, networking, and system diagnostics.
# ──────────────────────────────────────────────────────────────────────────────

# ── 1. LOG ANALYSIS & TEXT PROCESSING ─────────────────────────────────────────

# Search for errors case-insensitively and print columns: $1(date), $2(time), $3(level), $NF(last column)
grep -i "error" /path/to/log/file.log | awk '{print $1, $2, $3, $NF}'

#  -n for 'no new line' & -c for count
echo -n "ERROR : " && grep -c "ERROR" /path/to/log/file.log
#  Command substitution ($(...))
echo "ERROR : $(grep -c "ERROR" /path/to/log/file.log)"


# Count and rank top 5 IP addresses hitting a service (e.g. from access logs)
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -nr | head -n 5

# 1. Replace all occurrences of "http://" with "https://" in-place in a file:
sed -i 's/http:\/\//https:\/\//g' config.yaml

# 2. Print only lines between line 50 and 60:
sed -n '50,60p' /var/log/syslog

# Slicing fields by delimiter (e.g., extract username and home directory from passwd)
cut -d':' -f1,6 /etc/passwd | head -n 5

# Stream live log entries with initial tail buffer of 50 lines
tail -50f /var/log/nginx/error.log

# Follow systemd service logs in real time (e.g., kubelet or docker)
journalctl -u kubelet -f --no-tail


# ── 2. FILE & DISK TROUBLESHOOTING ─────────────────────────────────────────────

# Find and delete log files older than 7 days
find /var/log/apps -type f -name "*.log" -mtime +7 -delete

# Find files larger than 100MB across filesystem
find / -xdev -type f -size +100M -exec ls -lh {} + 2>/dev/null

# Check filesystem disk usage in human-readable format
df -h

# Find top 5 largest directories in current working directory
du -ah . --max-depth=1 2>/dev/null | sort -rh | head -n 5


# ── 3. PROCESS & RESOURCE MONITORING ───────────────────────────────────────────

# List top 5 CPU-consuming processes
ps aux --sort=-%cpu | head -n 6

# List top 5 Memory-consuming processes
ps aux --sort=-%mem | head -n 6

# Check which process is listening on a given port (e.g. 8080)
lsof -i :8080

# Socket statistics: list all listening TCP ports and their PID
ss -tulpn | grep -E ':(80|443|3000|5432|8080)'

# Check memory and swap usage in human-readable format
free -h


# ── 4. NETWORKING & CONNECTIVITY (K8S / CONTAINER DEBUGGING) ───────────────────

# Inspect HTTP status code and latency without printing body
curl -s -o /dev/null -w "HTTP: %{http_code} | Total Time: %{time_total}s\n" https://api.example.com/healthz

# Test raw TCP port connectivity with a 3-second timeout (e.g. Postgres port 5432)
nc -zv -w3 postgres-db.internal.vpc 5432

# Test Kubernetes in-cluster DNS resolution
dig +short taskmanager-service.taskmanager.svc.cluster.local

# Check routing table and default gateway
ip route show


# ── 5. USEFUL POWER ONE-LINERS ─────────────────────────────────────────────────

# Search recursively for a string across files, ignoring binary files
grep -rnI "DB_PASSWORD" /etc/ /app/ 2>/dev/null

# Kill all hung or zombie processes by name pattern
# pkill -9 -f "stuck-process-name"

# Monitor live socket changes every 2 seconds
# watch -n 2 'ss -s'

# Create a compressed timestamped tar archive of a directory
# tar -czvf app-backup-$(date +%F).tar.gz /app/data
