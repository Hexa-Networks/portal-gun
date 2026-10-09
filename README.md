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

## Uso

```bash
./start.sh            # pergunta usuário/senha/PSK/ASN em um dialog, grava .env (chmod 600) e sobe tudo
./start.sh --reconfig # pergunta tudo de novo
```

Verificação:

```bash
docker compose ps
docker compose logs -f vpn
docker exec -it portal-gun-frr vtysh -c 'show bgp summary'
ip route | grep 128.128.0.2      # rotas aprendidas no host
```

Parar: `docker compose down`.

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

## Limitações

- A senha MD5 do BGP (TCP-MD5) não funciona, porque a sessão passa por NAT no container vpn.
- A PSK e a senha não podem conter aspas (`'` ou `"`).
