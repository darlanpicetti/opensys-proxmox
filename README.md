# OpenSys Web Guardian — instalador Proxmox (público)

Scripts para criar um CT Debian 12 no Proxmox e instalar o painel nativo até o wizard `/bem-vindo`.

O código do produto permanece no repositório privado `e2guardian-ui`. Este repo só publica o que a instalação online precisa.

## One-liner (host Proxmox, root)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/darlanpicetti/opensys-proxmox/main/proxmox/ct/opensys-web-guardian.sh)"
```

Ao terminar: `http://<IP-do-CT>:5001/bem-vindo`

Hostname padrão do CT: **`opensys-wg`** (CTID = próximo livre). Para definir:

```bash
CTID=120 HOSTNAME=opensys-cliente1 \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/darlanpicetti/opensys-proxmox/main/proxmox/ct/opensys-web-guardian.sh)"
```

## Conteúdo

| Caminho | Função |
|---------|--------|
| `proxmox/ct/` | Script no host Proxmox (`pct create`) |
| `proxmox/install/` | Bootstrap dentro do CT |
| `seeds/policy-seed.tar.gz` | Grupos/políticas de fábrica (DEC-008) |
| `requirements.txt` | Deps Python do painel (native) |
| `critical-*.json` | Listas críticas iniciais |

Pacotes do produto (`opensys-ui`, etc.) vêm do registry Buildkite público.

## Docs

Detalhe de aceite e troubleshooting: no produto privado, `docs/PROXMOX_CT.md`.
