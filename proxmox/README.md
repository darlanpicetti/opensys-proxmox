# OpenSys Web Guardian — instalação em CT Proxmox (Fase B)

Scripts self-contained. **Canal público:** [opensys-proxmox](https://github.com/darlanpicetti/opensys-proxmox).

| Arquivo | Onde roda |
|---------|-----------|
| [`ct/opensys-web-guardian.sh`](ct/opensys-web-guardian.sh) | Host Proxmox VE |
| [`install/opensys-web-guardian-install.sh`](install/opensys-web-guardian-install.sh) | Dentro do CT (Debian 12) |
| [`defaults.env`](defaults.env) | Defaults (RAM, disco, bridge, registry) |

Documentação: [`docs/PROXMOX_CT.md`](../docs/PROXMOX_CT.md).

## One-liner (cliente)

No shell **root** do Proxmox:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/darlanpicetti/opensys-proxmox/main/proxmox/ct/opensys-web-guardian.sh)"
```

Ao terminar: `http://<IP-do-CT>:5001/bem-vindo`

## Checkout local (repo produto)

```bash
sudo bash proxmox/ct/opensys-web-guardian.sh
```

## Requisitos

- Proxmox VE com `pct` / `pveam`
- Internet no host (template Debian 12) e no CT (Buildkite apt + seeds públicos)
- CT **privilegiado** (default do piloto)
- Registry Buildkite com `opensys-ui` ≥ **1.4.12** (pin `OPENSYS_UI_MIN_VERSION` no install)

## O que o bootstrap garante (bugs piloto)

| Item | Proteção |
|------|----------|
| P1 helpers Logs/Rede | postinst + cópia para `/opt/opensys/bin` |
| P5 sudoers CA/filtro | `90-opensys-services` |
| P6 MSI agente | embutido no `.deb` `static/OpenWebFence.msi` |
| P8 versão antiga | `OPENSYS_UI_MIN_VERSION` + checklist |
| P10 phraselist / filter0 | reparo pós-seed + permissões `ipgroups` |
| P12 retenção de logs | `opensys-logs retention-*` + UI Sistema→Logs (≥ 1.4.11) |
| Checklist | falha o install se item crítico faltar |
