<#
.SYNOPSIS
    Diagnóstico do portal-gun no Windows: Windows -> distro WSL -> container vpn -> túnel.
.EXAMPLE
    .\windows\diag.ps1             # testa com o primeiro destino /32 aprendido via BGP
    .\windows\diag.ps1 10.1.2.3    # testa com um destino específico
#>
param([string]$Target, [string]$Distro = 'portal-gun')

$env:WSL_UTF8 = '1'
$Dir = Join-Path $env:ProgramData 'portal-gun'
function H($m) { Write-Host ""; Write-Host "===== $m =====" -ForegroundColor Cyan }
function W([string]$cmd) {
    # Script em base64: o Windows PowerShell 5.1 corrompe aspas em argumentos de programas externos
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($cmd -replace "`r", '')))
    & wsl.exe -d $Distro -u root -- bash -c "echo $b64 | base64 -d | bash"
}

H 'Windows'
& wsl.exe -l -v
$task = Get-ScheduledTask -TaskName 'portal-gun' -ErrorAction SilentlyContinue
Write-Host "tarefa portal-gun: $(if ($task) { $task.State } else { 'NÃO INSTALADA' })"
W 'cd /opt/portal-gun && docker compose ps'
W 'docker inspect portal-gun-frr portal-gun-vpn >/dev/null 2>&1'
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '>>> Os containers não estão rodando. Suba com: wsl -d portal-gun -u root -- bash -c "cd /opt/portal-gun && docker compose up -d"' -ForegroundColor Yellow
    exit 1
}

$wslIp = ([regex]::Match((W 'ip -4 -o addr show eth0') -join ' ', 'inet (\d+\.\d+\.\d+\.\d+)/')).Groups[1].Value
if ($Target -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    $Target = (W "ip -4 route show proto bgp | awk '`$1 !~ /\//{print `$1; exit}'" | Select-Object -First 1)
}
Write-Host "IP da distro: $wslIp   destino de teste: $Target"
Write-Host "rotas no Windows via distro: $(@(Get-NetRoute -AddressFamily IPv4 -NextHop $wslIp -ErrorAction SilentlyContinue).Count)"
Find-NetRoute -RemoteIPAddress $Target -ErrorAction SilentlyContinue | Where-Object { $_.NextHop } |
    Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric | Format-Table -AutoSize

H 'route-sync'
if (Test-Path "$Dir\route-sync.log") { Get-Content "$Dir\route-sync.log" -Tail 5 }

H 'BGP / logs'
W "docker exec portal-gun-frr vtysh -c 'show bgp summary' | grep -A2 Neighbor"
W "docker logs portal-gun-frr 2>&1 | grep '\[frr\]'"
W "docker logs portal-gun-vpn 2>&1 | grep -E '\[vpn\]|CHAP auth' | tail -6"

H 'distro WSL (host)'
W "uname -r; sysctl -n net.ipv4.ip_forward; ip -br a | grep -v veth; ip route | grep -v 'proto bgp'; echo '-- rota para ${Target}:'; ip route get $Target; echo '-- DOCKER-USER'; iptables -L DOCKER-USER -v -n"

H 'container vpn'
W "docker exec portal-gun-vpn sh -c 'ip route; ip rule | grep fwmark; ip route show table 100; iptables -t nat -L PG-NAT -v -n; iptables -t mangle -L PREROUTING -v -n'"

H "captura durante o ping para $Target"
$cap = Join-Path $env:TEMP 'portal-gun-cap.txt'
$p = Start-Process -FilePath 'wsl.exe' -NoNewWindow -PassThru -RedirectStandardOutput $cap -ArgumentList `
    "-d $Distro -u root -- docker run --rm --net host --cap-add NET_ADMIN --cap-add NET_RAW nicolaka/netshoot:v0.13 timeout 12 tcpdump -lni any -c 20 icmp and host $Target"
Start-Sleep -Seconds 5
Write-Host '--- ping a partir da distro (origem 128.128.0.1)'
W "docker run --rm --net host nicolaka/netshoot:v0.13 ping -c2 -W2 $Target"
Write-Host '--- ping a partir do Windows'
& ping.exe -n 3 $Target
$p.WaitForExit(15000) | Out-Null
Get-Content $cap | ForEach-Object { "[WSL] $_" }
