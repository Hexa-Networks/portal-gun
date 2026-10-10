#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Instala o portal-gun no Windows: distro WSL2 dedicada + Docker Engine + containers + sincronização de rotas.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\windows\setup.ps1
#>
param(
    [string]$Distro = 'portal-gun',
    [string]$Repo   = 'https://github.com/Hexa-Networks/portal-gun.git',
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'                       # saída do wsl.exe em UTF-8 (não UTF-16)
$ProgramDir = Join-Path $env:ProgramData 'portal-gun'
$TaskName = 'portal-gun'

function Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Die($m)  { Write-Host "ERRO: $m" -ForegroundColor Red; exit 1 }
function WslRun {
    # Roda um script bash como root na distro e devolve o exit code. O script vai em base64
    # porque o Windows PowerShell 5.1 corrompe aspas em argumentos de programas externos.
    # Também remove o CR do CRLF (os .ps1 ficam com CRLF no Windows).
    param([string]$Cmd)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Cmd -replace "`r", '')))
    & wsl.exe -d $Distro -u root -- bash -c "echo $b64 | base64 -d | bash" | Out-Host
    return $LASTEXITCODE
}
function Wsl {
    # Igual ao WslRun, mas aborta se o comando falhar
    param([string]$Cmd)
    $rc = WslRun $Cmd
    if ($rc -ne 0) { throw "falhou dentro do WSL (exit $rc): $Cmd" }
}

# ---------------------------------------------------------------------------
Step 'Verificando o Windows e o WSL'
$build = [Environment]::OSVersion.Version.Build
if ($build -lt 19045) { Die "precisa do Windows 10 22H2 (build 19045) ou Windows 11. Build atual: $build" }

& wsl.exe --status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Instalando o WSL...'
    & wsl.exe --install --no-distribution
    Die 'WSL instalado. Reinicie o Windows e rode este script de novo.'
}
& wsl.exe --update
& wsl.exe --version

$wslconfig = Join-Path $env:USERPROFILE '.wslconfig'
if ((Test-Path $wslconfig) -and (Select-String -Path $wslconfig -Pattern '^\s*networkingMode\s*=\s*mirrored' -Quiet)) {
    Die "o $wslconfig usa networkingMode=mirrored. O portal-gun precisa do modo NAT (padrão): a VM precisa de um IP próprio para o Windows rotear até ela. Remova essa linha, rode 'wsl --shutdown' e tente de novo."
}

# ---------------------------------------------------------------------------
Step "Criando a distro WSL '$Distro' (Ubuntu 24.04)"
$distros = (& wsl.exe -l -q) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($distros -contains $Distro) {
    Write-Host 'distro já existe'
} else {
    & wsl.exe --install -d Ubuntu-24.04 --name $Distro --no-launch
    if ($LASTEXITCODE -ne 0) { Die "não consegui criar a distro (o WSL precisa ser 2.4.4 ou mais novo para --name)" }
}

Wsl "printf '[boot]\nsystemd=true\n[user]\ndefault=root\n' > /etc/wsl.conf"
& wsl.exe --terminate $Distro | Out-Null
Wsl 'systemctl is-system-running --wait >/dev/null 2>&1 || true; echo "systemd: $(systemctl is-system-running)"'

# ---------------------------------------------------------------------------
Step 'Verificando os módulos de kernel (L2TP/PPP/IPsec) no kernel do WSL'
$rc = WslRun @'
modprobe -a ppp_generic pppox l2tp_core l2tp_netlink l2tp_ppp esp4 xfrm_user 2>&1
for m in ppp_generic l2tp_ppp esp4 xfrm_user; do
    if [ -d /sys/module/$m ]; then echo "  ok      $m"; else echo "  FALTA   $m"; miss=1; fi
done
exit ${miss:-0}
'@
if ($rc -ne 0) {
    Write-Host ''
    Write-Host 'Configuração do kernel do WSL:' -ForegroundColor Yellow
    WslRun @'
uname -r
zgrep -E '^# CONFIG_(PPP|L2TP|INET_ESP|XFRM_USER)[ =]|^CONFIG_(PPP|L2TP|PPPOL2TP|INET_ESP|XFRM_USER)[_A-Z]*=' /proc/config.gz 2>/dev/null
'@ | Out-Null
    Die 'o kernel do WSL não tem os módulos necessários. Mande esta saída para o NOC: será preciso um kernel WSL customizado (.wslconfig -> kernel=...).'
}

# ---------------------------------------------------------------------------
Step 'Instalando o Docker Engine na distro'
Wsl 'command -v docker >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl git whiptail && curl -fsSL https://get.docker.com | sh; }'
Wsl 'systemctl enable --now docker >/dev/null 2>&1; docker version --format "docker {{.Server.Version}}"'

Step 'Baixando o portal-gun dentro do WSL (/opt/portal-gun)'
Wsl "if [ -d /opt/portal-gun/.git ]; then git -C /opt/portal-gun pull --ff-only; else git clone -b $Branch $Repo /opt/portal-gun; fi"

Step 'Configurando o .env'
Wsl @'
cd /opt/portal-gun
[ -f .env ] || cp .env.example .env
chmod 600 .env
sed -i '/^ALLOW_FORWARD=/d' .env
echo "ALLOW_FORWARD='yes'" >> .env
'@

Step 'Credenciais e containers (start.sh)'
& wsl.exe -d $Distro -u root -- bash -c 'cd /opt/portal-gun && ./start.sh'
if ($LASTEXITCODE -ne 0) { Die 'start.sh falhou' }

Step 'Serviço systemd dentro do WSL (sobe os containers quando a distro inicia)'
Wsl 'cd /opt/portal-gun && echo n | ./install.sh >/dev/null && systemctl is-enabled portal-gun'

# ---------------------------------------------------------------------------
Step 'Instalando a sincronização de rotas no Windows (tarefa agendada)'
New-Item -ItemType Directory -Force -Path $ProgramDir | Out-Null
# Só administradores podem alterar o script que roda com privilégio elevado
& icacls.exe $ProgramDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'route-sync.ps1') (Join-Path $ProgramDir 'route-sync.ps1')
@{ Distro = $Distro } | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $ProgramDir 'route-sync.json')

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ProgramDir\route-sync.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $TaskName

# ---------------------------------------------------------------------------
Step 'Aguardando as rotas chegarem no Windows (até 3 min)'
$wslIp = ((& wsl.exe -d $Distro -u root -- ip -4 -o addr show eth0) -split '\s+' | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+/' } | Select-Object -First 1) -replace '/.*', ''
$n = 0
for ($i = 0; $i -lt 36; $i++) {
    $n = @(Get-NetRoute -AddressFamily IPv4 -NextHop $wslIp -ErrorAction SilentlyContinue).Count
    if ($n -gt 0) { break }
    Start-Sleep -Seconds 5
}
Write-Host "Rotas no Windows via $wslIp : $n"

Write-Host @"

Pronto. Comandos úteis (PowerShell):
  wsl -d $Distro -- docker ps                                              # containers
  wsl -d $Distro -- docker exec portal-gun-frr vtysh -c 'show bgp summary' # sessão BGP
  .\windows\diag.ps1                                                       # diagnóstico completo
  Get-Content $ProgramDir\route-sync.log -Tail 20 -Wait                    # log da sincronização
  .\windows\update.ps1                                                     # atualizar
  .\windows\uninstall.ps1                                                  # remover
"@
