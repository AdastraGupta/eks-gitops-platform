# -----------------------------------------------------------------------------
# Local Pre-Flight and Security Validation Script (PowerShell for Windows)
# Run before committing or pushing: .\scripts\validate-local.ps1
# -----------------------------------------------------------------------------

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "[*] Running Local Pre-Flight and Security Validation" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

$FailedCount = 0

# 1. Terraform Format Check
Write-Host "`n[1/5] Checking Terraform Formatting..." -ForegroundColor Yellow
terraform -chdir=terraform fmt -check -diff -recursive
if ($LASTEXITCODE -eq 0) {
    Write-Host "[PASS] Terraform formatting is clean!" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Terraform format issues found. Run: terraform -chdir=terraform fmt -recursive" -ForegroundColor Red
    $FailedCount++
}

# 2. Kubernetes YAML Syntax Validation
Write-Host "`n[2/5] Validating Kubernetes Manifests (k8s/*.yaml)..." -ForegroundColor Yellow
python -c @"
import os, sys, yaml
errs = 0
for root, _, files in os.walk('k8s'):
    for f in files:
        if f.endswith(('.yaml', '.yml')):
            path = os.path.join(root, f)
            try:
                with open(path, 'r', encoding='utf-8') as s:
                    list(yaml.safe_load_all(s))
            except Exception as e:
                print(f'[FAIL] Error in {path}: {e}')
                errs += 1
if errs > 0:
    sys.exit(1)
print('[PASS] All k8s/*.yaml manifests are valid YAML!')
"@
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FAIL] Kubernetes YAML validation failed." -ForegroundColor Red
    $FailedCount++
}

# 3. Helm Chart Linting
Write-Host "`n[3/5] Linting Helm Charts (charts/taskmanager)..." -ForegroundColor Yellow
if (Get-Command helm -ErrorAction SilentlyContinue) {
    helm lint charts/taskmanager
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[PASS] Helm lint passed!" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Helm linting failed." -ForegroundColor Red
        $FailedCount++
    }
} else {
    Write-Host "[INFO] Helm CLI not found. Skipping Helm lint." -ForegroundColor Gray
}

# 4. Checkov Compliance Scan (if installed)
Write-Host "`n[4/5] Checking Checkov Compliance Scanner..." -ForegroundColor Yellow
if (Get-Command checkov -ErrorAction SilentlyContinue) {
    checkov -d terraform/ --framework terraform --compact --quiet --soft-fail
    Write-Host "[PASS] Checkov scan completed!" -ForegroundColor Green
} else {
    Write-Host "[INFO] Checkov not installed locally. Run 'pip install checkov' to enable local CIS benchmark audits." -ForegroundColor Gray
}

# 5. Gitleaks Secret Detection (if installed)
Write-Host "`n[5/5] Checking Gitleaks Secret Scanner..." -ForegroundColor Yellow
if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
    gitleaks detect --source=. --config-path=.gitleaks.toml --verbose --redact
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[PASS] No secrets detected by Gitleaks!" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Gitleaks detected potential secrets!" -ForegroundColor Red
        $FailedCount++
    }
} else {
    Write-Host "[INFO] Gitleaks not installed locally. (Runs automatically in GitHub Actions PR checks)." -ForegroundColor Gray
}

Write-Host "`n=====================================================" -ForegroundColor Cyan
if ($FailedCount -eq 0) {
    Write-Host "[SUCCESS] All local validation checks passed! Ready to push." -ForegroundColor Green
} else {
    Write-Host "[ERROR] Found $FailedCount validation issue(s). Please review above errors." -ForegroundColor Red
    exit 1
}
Write-Host "=====================================================" -ForegroundColor Cyan
