#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Remove o portal-gun do Windows: tarefa agendada, rotas, containers e (se confirmado) a distro WSL.
#>
param([string]$Distro = 'portal-gun')

$env:WSL_UTF8 = '1'
$ProgramDir = Join-Path $env:ProgramData 'portal-gun'

Write-Host '==> Parando a sincronização de rotas e removendo as rotas'
Stop-ScheduledTask -TaskName 'portal-gun' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'portal-gun' -Confirm:$false -ErrorAction SilentlyContinue
if (Test-Path (Join-Path $ProgramDir 'route-sync.ps1')) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ProgramDir 'route-sync.ps1') -Flush
}

Write-Host '==> Derrubando os containers'
& wsl.exe -d $Distro -u root -- bash -c 'cd /opt/portal-gun 2>/dev/null && systemctl disable --now portal-gun 2>/dev/null; docker compose down 2>/dev/null'

$ans = Read-Host "Apagar também a distro WSL '$Distro' (tudo dentro dela, inclusive o .env)? [s/N]"
if ($ans -match '^[sSyY]$') {
    & wsl.exe --unregister $Distro
} else {
    & wsl.exe --terminate $Distro | Out-Null
}
Remove-Item -Recurse -Force $ProgramDir -ErrorAction SilentlyContinue
Write-Host 'Removido.'
