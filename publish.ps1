param(
  [Parameter(Position = 0)]
  [string]$Message = 'update'
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

git add -A
$staged = git diff --cached --name-only
if (-not $staged) { Write-Host 'Nothing to publish.'; exit 0 }

git commit -m $Message
git push
Write-Host ''
Write-Host 'Published. GitHub Actions is now building.' -ForegroundColor Green
Write-Host 'Status: https://github.com/bikini/bikini.github.io/actions'
