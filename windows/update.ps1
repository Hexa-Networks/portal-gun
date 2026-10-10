#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Atualiza o portal-gun no Windows: containers na distro WSL (update.sh) e scripts do Windows.
.EXAMPLE
    .\windows\update.ps1           # mostra o que mudou e pergunta
    .\windows\update.ps1 -Check    # só verifica
#>
param([switch]$Check, [string]$Distro = 'portal-gun')

$env:WSL_UTF8 = '1'
$ProgramDir = Join-Path $env:ProgramData 'portal-gun'
$RepoRoot = Split-Path $PSScriptRoot -Parent

if ($Check) {
    & wsl.exe -d $Distro -u root -- bash -c 'cd /opt/portal-gun && ./update.sh --check'
    exit $LASTEXITCODE
}

# 1) Containers e código dentro do WSL
& wsl.exe -d $Distro -u root -- bash -c 'cd /opt/portal-gun && ./update.sh'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# 2) Scripts do Windows (este clone) e route-sync instalado
if ((Test-Path (Join-Path $RepoRoot '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    & git -C $RepoRoot pull --ff-only
} else {
    Write-Host "Aviso: $RepoRoot não é um clone git; os scripts do Windows não foram atualizados." -ForegroundColor Yellow
}
Copy-Item -Force (Join-Path $PSScriptRoot 'route-sync.ps1') (Join-Path $ProgramDir 'route-sync.ps1')
Stop-ScheduledTask -TaskName 'portal-gun' -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName 'portal-gun'
Write-Host 'route-sync atualizado e reiniciado.'
