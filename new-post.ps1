param(
  [Parameter(Position = 0, Mandatory = $true)]
  [string]$Title,

  [Parameter(Position = 1)]
  [ValidateSet('writeups', 'exploits', 'research')]
  [string]$Category = 'research',

  [string]$Description = '',
  [switch]$NoPush
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$slug = $Title.ToLower() -replace '[^\w\s-]', '' -replace '\s+', '-' -replace '-+', '-'
$slug = $slug.Trim('-')
if (-not $slug) { Write-Error 'Could not derive a slug from the title.'; exit 1 }

$now = Get-Date
$datePart = $now.ToString('yyyy-MM-dd')
$postDir = Join-Path $PSScriptRoot 'src/content/blog'
$file = Join-Path $postDir "$datePart-$slug.md"

if (Test-Path $file) { Write-Error "Post already exists: $file"; exit 1 }
if (-not $Description) { $Description = $Title }

$titleEsc = $Title -replace "'", "''"
$descEsc = $Description -replace "'", "''"
$pubDate = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')

$frontmatter = @"
---
title: '$titleEsc'
description: '$descEsc'
pubDate: '$pubDate'
category: '$Category'
---

Write your post here in **markdown**.
"@

Set-Content -Path $file -Value $frontmatter -Encoding UTF8
Write-Host "Created [$Category] $file" -ForegroundColor Green

$editor =
  if (Get-Command code -ErrorAction SilentlyContinue) { 'code' }
  elseif ($env:EDITOR) { $env:EDITOR }
  else { 'notepad' }

Write-Host "Opening in $editor (close the editor when done)..."
if ($editor -eq 'code') { & code --wait $file } else { & $editor $file }

if ($NoPush) {
  Write-Host 'Saved. Run .\publish.ps1 when ready to push.'
  exit 0
}

git add -- $file | Out-Null
git commit -m "post($Category): $Title" | Out-Null
git push
Write-Host ''
Write-Host 'Published. GitHub Actions is now building.' -ForegroundColor Green
Write-Host "Status:   https://github.com/bikini/bikini.github.io/actions"
Write-Host "Live in ~1-2 min: https://bikini.github.io/blog/$datePart-$slug/"
