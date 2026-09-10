#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Local Pre-Flight & Security Validation Script (Bash)
# Run before committing or pushing: ./scripts/validate-local.sh
# ─────────────────────────────────────────────────────────────────────────────

set -e

echo "====================================================="
echo "🔍 Running Local Pre-Flight & Security Validation"
echo "====================================================="

FAILED=0

# 1. Terraform Format Check
echo ""
echo "[1/5] Checking Terraform Formatting..."
if terraform -chdir=terraform fmt -check -diff -recursive; then
    echo "✅ Terraform formatting is clean!"
else
    echo "❌ Terraform format issues found. Run: terraform -chdir=terraform fmt -recursive"
    FAILED=$((FAILED + 1))
fi

# 2. Kubernetes YAML Syntax Validation
echo ""
echo "[2/5] Validating Kubernetes Manifests (k8s/*.yaml)..."
if python3 -c '
import os, sys, yaml
errs = 0
for root, _, files in os.walk("k8s"):
    for f in files:
        if f.endswith((".yaml", ".yml")):
            path = os.path.join(root, f)
            try:
                with open(path, "r", encoding="utf-8") as s:
                    list(yaml.safe_load_all(s))
            except Exception as e:
                print(f"❌ Error in {path}: {e}")
                errs += 1
if errs > 0:
    sys.exit(1)
print("✅ All k8s/*.yaml manifests are valid YAML!")
'; then
    :
else
    FAILED=$((FAILED + 1))
fi

# 3. Helm Chart Linting
echo ""
echo "[3/5] Linting Helm Charts (charts/taskmanager)..."
if command -v helm &>/dev/null; then
    if helm lint charts/taskmanager; then
        echo "✅ Helm lint passed!"
    else
        echo "❌ Helm linting failed."
        FAILED=$((FAILED + 1))
    fi
else
    echo "⚠️ Helm CLI not found. Skipping Helm lint."
fi

# 4. Checkov Compliance Scan (if installed)
echo ""
echo "[4/5] Running Checkov Compliance Scan..."
if command -v checkov &>/dev/null; then
    checkov -d terraform/ --framework terraform --compact --quiet --soft-fail || true
    echo "✅ Checkov scan completed!"
else
    echo "ℹ️ Checkov not installed locally. Run 'pip install checkov' to enable local CIS benchmark audits."
fi

# 5. Gitleaks Secret Detection (if installed)
echo ""
echo "[5/5] Running Gitleaks Secret Scan..."
if command -v gitleaks &>/dev/null; then
    if gitleaks detect --source=. --config-path=.gitleaks.toml --verbose --redact; then
        echo "✅ No secrets detected by Gitleaks!"
    else
        echo "❌ Gitleaks detected potential secrets!"
        FAILED=$((FAILED + 1))
    fi
else
    echo "ℹ️ Gitleaks not installed locally. (Runs automatically in GitHub Actions PR checks)."
fi

echo ""
echo "====================================================="
if [ "$FAILED" -eq 0 ]; then
    echo "🎉 All local validation checks passed! Ready to push."
else
    echo "❌ Found $FAILED validation issue(s). Please review above errors."
    exit 1
fi
echo "====================================================="
