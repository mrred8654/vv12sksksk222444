# AquaVR - helper: stage + commit + push to origin/main
$ErrorActionPreference = "Stop"

git add -A

# If nothing staged, do nothing
$staged = git diff --cached --compact-summary
if (-not $staged) {
    Write-Host "No changes to commit."
    exit 0
}

git commit -m "AquaVR: update from local PC"
Write-Host "Pushing to origin/main ..."
git push -u origin main
Write-Host "Done. Check GitHub -> Actions tab."
