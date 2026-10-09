# portal-gun

Fecha uma VPN **L2TP/IPsec** com o LNS da Hexa (VPN-SERVER) e, por dentro dela, uma sessão **BGP** com FRR.
As rotas aprendidas são instaladas na tabela de rotas do **host** e o tráfego para elas segue pelo túnel.

## Arquitetura

```
                       host Linux
 ┌───────────────────────────────────────────────────────────┐
 │  frr (network_mode: host)            vpn container        │
 │  bgpd/zebra/staticd                  strongSwan + xl2tpd  │
 │  rotas BGP -> via 128.128.0.2        pppd (ppp0)          │
 │        │                                 │                │
 │   128.128.0.1 ──── bridge pgun0 ──── 128.128.0.2          │
 │                  128.128.0.0/24          │ ppp0 (L2TP)    │
 └──────────────────────────────────────────┼────────────────┘
                                            │ IPsec (IKEv1 transport)
                                            ▼
                                  LNS 203.0.113.10
```

- **vpn**: sobe o IPsec e o L2TP, recebe o IP via PPP e passa a rotear para o `ppp0` tudo o que chega pela rede de trânsito.
  - Faz NAT da origem para o IP PPP, menos para os prefixos de `BGP_NETWORKS`.
  - Faz DNAT da porta TCP/179 que chega pelo túnel para o FRR.
- **frr**: roda no namespace de rede do host e fecha BGP com o peer PPP (no tutorial, `192.0.2.1`) passando pelo `128.128.0.2`.
  - As rotas recebidas entram no kernel do host com next-hop `128.128.0.2`.
  - Filtros de entrada:
    - a rota default é recusada (ajuste com `BGP_ACCEPT_DEFAULT`);
    - prefixos da rede de trânsito são recusados;
    - o /32 do LNS é recusado, e existe uma rota fixa para o LNS pela default do host para evitar loop.
- Os dois containers trocam o estado da sessão PPP (IP local e IP do peer) por um volume compartilhado. Se a sessão reconectar com outro IP, o FRR é recarregado sozinho.
- **Reconexão:** se o `ppp0` ficar fora por mais de 45s, o watchdog do container vpn refaz o IPsec e o L2TP. As tentativas acontecem a cada ~50s, para não sobrecarregar o RADIUS. Os containers usam `restart: unless-stopped` e sobem sozinhos após reboot.

Caminho de um pacote do host até uma rede aprendida (traceroute real):

```
1  128.128.0.2      container vpn (rede de trânsito)
2  192.0.2.1    LNS, dentro do túnel
3  172.16.0.1
4  172.16.1.1
```

## Pré-requisitos no LNS

Cada cliente precisa de:

1. Usuário L2TP no RADIUS **com IP fixo** (`Framed-IP-Address`), por exemplo `192.0.2.52`.
2. Sessão BGP no LNS apontando para esse IP, AS remoto `65000` (iBGP), como no tutorial do VPN-SERVER.

## Uso

```bash
git clone https://github.com/Hexa-Networks/portal-gun.git
cd portal-gun
./start.sh            # pergunta usuário/senha/PSK/ASN em um dialog, grava .env (chmod 600) e sobe tudo
./start.sh --reconfig # pergunta tudo de novo
```

O `.env` com as credenciais fica só na máquina; ele está no `.gitignore`.

Verificação:

```bash
docker compose ps                                            # vpn deve ficar "healthy"
docker compose logs -f vpn                                   # IPsec, L2TP e PPP
docker exec -it portal-gun-frr vtysh -c 'show bgp summary'   # sessão BGP e prefixos recebidos
ip route | grep 128.128.0.2                                  # rotas aprendidas no host
```

Parar: `docker compose down`. Subir de novo: `docker compose up -d`.

> O usuário precisa estar no grupo `docker` (`usermod -aG docker <usuario>`, depois logout/login).

## Configuração

Todas as opções estão em `.env.example`. As mais usadas:

| Variável | Padrão | Descrição |
|---|---|---|
| `LNS_IP` | `203.0.113.10` | IP do VPN-SERVER |
| `IPSEC_PSK`, `L2TP_USER`, `L2TP_PASS` | — | perguntadas pelo `start.sh` |
| `BGP_LOCAL_AS` / `BGP_REMOTE_AS` | `65000` / `65000` | iBGP por padrão; se forem diferentes, ativa `ebgp-multihop` |
| `BGP_NEIGHBOR` | `auto` | `auto` = IP do peer PPP |
| `BGP_NETWORKS` | vazio | prefixos anunciados ao LNS (separados por espaço) |
| `BGP_ACCEPT_DEFAULT` | `no` | aceitar 0.0.0.0/0 do LNS |
| `TRANSIT_SUBNET` | `128.128.0.0/24` | rede entre host/FRR e o container vpn |

## Requisitos do host

- Docker e o plugin Docker Compose.
- Kernel com `l2tp_ppp`, `ppp_generic`, `esp4` e `xfrm_user`. O container `vpn` carrega esses módulos sozinho, montando `/lib/modules`.
- Nenhum outro IKE (strongSwan/libreswan) usando as portas UDP 500/4500 no host.

## Diagnóstico

| Sintoma (logs) | Causa | Onde resolver |
|---|---|---|
| IPsec não fecha (`NO_PROPOSAL_CHOSEN`, `AUTHENTICATION_FAILED` no `[IKE]`) | PSK errada ou proposta incompatível | `IPSEC_PSK`, `IPSEC_IKE` e `IPSEC_ESP` no `.env` |
| `CHAP authentication failed` + `radius timeout` | usuário errado ou RADIUS sem responder ao LNS | conferir o usuário, ver `/radius monitor` no LNS |
| PPP sobe, BGP fica `Active`/`Idle` com `Waiting for peer OPEN` | o LNS aceita o TCP/179 e fecha: não existe sessão BGP para o IP do cliente | criar a sessão BGP no LNS |
| BGP `Established`, mas um destino não passa pela VPN | a LAN local do host cobre esse destino (rota conectada ganha da rota BGP) | ver a seção Limitações |

Para ver a negociação PPP em detalhe, coloque `PPP_EXTRA_OPTS='debug;logfd 2'` no `.env` e rode `docker compose up -d --force-recreate vpn`.

## Limitações

- A senha MD5 do BGP (TCP-MD5) não funciona, porque a sessão passa por NAT no container vpn.
- A PSK e a senha não podem conter aspas (`'` ou `"`).
- **Sobreposição com a LAN local:** se a rede local do host coincidir com um prefixo anunciado pelo LNS, a rota conectada ganha e essa faixa sai pela LAN, não pela VPN. Por exemplo: um host na `192.168.10.0/24` não acessa `192.168.10.x` pela VPN, mesmo recebendo `192.168.0.0/16`. Em produção, os clientes devem usar uma LAN que não colida com os prefixos do LNS.
- A rota default recebida do LNS é recusada por padrão. A internet do host continua saindo pelo link local.
