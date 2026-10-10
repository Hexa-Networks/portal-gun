<#
.SYNOPSIS
    Sincroniza as rotas BGP aprendidas na distro WSL do portal-gun para a tabela de rotas do Windows.
.DESCRIPTION
    Roda pela tarefa agendada "portal-gun" (no logon, com privilégio elevado). A cada IntervalSeconds:
      - mantém a distro WSL viva (o WSL desliga distros sem processos);
      - lê as rotas "proto bgp" da distro (container portal-gun-frr);
      - adiciona no Windows as novas (gateway = IP da distro) e remove as que sumiram;
      - se a distro ou o FRR estiverem fora, remove todas (evita buraco negro).
    Só remove rotas que ele mesmo criou. As rotas ficam no ActiveStore (não persistem após reboot).
.PARAMETER Flush
    Remove as rotas criadas e sai (usado pelo uninstall.ps1).
#>
param([switch]$Flush, [int]$IntervalSeconds = 10)

$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'
$Dir = Join-Path $env:ProgramData 'portal-gun'
$Distro = (Get-Content (Join-Path $Dir 'route-sync.json') -Raw | ConvertFrom-Json).Distro
$LogFile = Join-Path $Dir 'route-sync.log'
$StateFile = Join-Path $Dir 'routes.state'       # linhas "prefixo gateway ifIndex"

function Log($m) {
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Move-Item -Force $LogFile "$LogFile.1" }
    Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
}

function Read-State {
    $s = @{}
    if (Test-Path $StateFile) {
        foreach ($l in Get-Content $StateFile) {
            $f = $l -split ' '
            if ($f.Count -eq 3) { $s[$f[0]] = @{ Gw = $f[1]; If = [int]$f[2] } }
        }
    }
    return $s
}

function Write-State($s) {
    # WriteAllLines também grava (trunca) quando a lista está vazia; Set-Content não faz nada sem entrada
    $lines = [string[]]@($s.GetEnumerator() | ForEach-Object { "{0} {1} {2}" -f $_.Key, $_.Value.Gw, $_.Value.If })
    [IO.File]::WriteAllLines($StateFile, $lines)
}

function Remove-AllRoutes {
    $s = Read-State
    if ($s.Count -eq 0) { return }
    foreach ($p in $s.Keys) {
        Remove-NetRoute -DestinationPrefix $p -InterfaceIndex $s[$p].If -NextHop $s[$p].Gw `
            -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-State @{}
    Log "removidas $($s.Count) rotas"
}

function Get-WslIp {
    $out = & wsl.exe -d $Distro -u root -- ip -4 -o addr show eth0 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $m = [regex]::Match(($out -join ' '), 'inet (\d+\.\d+\.\d+\.\d+)/')
    if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}

function Get-WslIfIndex($ip) {
    # Interface do Windows na mesma sub-rede da distro (vEthernet (WSL ...))
    $r = Find-NetRoute -RemoteIPAddress $ip -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($r) { return [int]$r.InterfaceIndex } else { return $null }
}

if ($Flush) { Remove-AllRoutes; exit 0 }

Log "iniciado (distro: $Distro, intervalo: ${IntervalSeconds}s)"
Remove-AllRoutes            # rotas de uma execução anterior são refeitas do zero
$keepalive = $null
$prevFailed = 0

while ($true) {
    # Mantém a distro viva
    if (-not $keepalive -or $keepalive.HasExited) {
        $keepalive = Start-Process -FilePath 'wsl.exe' -ArgumentList "-d $Distro -u root -- sleep infinity" -WindowStyle Hidden -PassThru
    }

    $ip = Get-WslIp
    $raw = $null
    if ($ip) {
        $raw = & wsl.exe -d $Distro -u root -- docker exec portal-gun-frr ip -4 route show proto bgp 2>$null
        if ($LASTEXITCODE -ne 0) { $raw = $null }
    }
    if (-not $ip -or $null -eq $raw) {
        if ((Read-State).Count -gt 0) { Log 'distro ou FRR indisponível'; Remove-AllRoutes }
        Start-Sleep -Seconds $IntervalSeconds
        continue
    }
    $if = Get-WslIfIndex $ip

    $want = @{}
    foreach ($l in @($raw)) {
        $p = ($l -split '\s+')[0]
        if (-not $p) { continue }
        if ($p -notmatch '/') { $p = "$p/32" }
        $want[$p] = $true
    }

    $state = Read-State
    if ($state.Count -gt 0) {
        $first = $state.Values | Select-Object -First 1
        if ($first.Gw -ne $ip -or $first.If -ne $if) {
            Log "IP/interface da distro mudou para $ip (if $if)"
            Remove-AllRoutes
            $state = @{}
        }
    }

    $added = 0; $removed = 0; $failed = 0
    foreach ($p in @($state.Keys)) {
        if (-not $want.ContainsKey($p)) {
            Remove-NetRoute -DestinationPrefix $p -InterfaceIndex $state[$p].If -NextHop $state[$p].Gw `
                -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
            $state.Remove($p); $removed++
        }
    }
    foreach ($p in $want.Keys) {
        if ($state.ContainsKey($p)) { continue }
        try {
            # Só registra o que foi realmente adicionado: assim nunca remove uma rota que não é nossa
            New-NetRoute -DestinationPrefix $p -InterfaceIndex $if -NextHop $ip -RouteMetric 5 `
                -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
            $state[$p] = @{ Gw = $ip; If = $if }; $added++
        } catch { $failed++ }
    }
    Write-State $state

    if ($added -gt 0 -or $removed -gt 0 -or $failed -ne $prevFailed) {
        Log "via $ip (if $if): +$added -$removed (falhas: $failed, total: $($state.Count))"
    }
    $prevFailed = $failed
    Start-Sleep -Seconds $IntervalSeconds
}
