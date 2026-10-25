# PalHost — Servidor Dedicado Palworld 1.0 para Windows

Servidor dedicado de **Palworld 1.0** totalmente automatizado em PowerShell: instalação com um comando, gerenciador de mods no estilo *package manager*, backups automáticos, reinício e atualização diários, proteção contra crash e travamento, painel gráfico de um clique e **migração para outro computador com dois comandos**.

> Projeto pessoal e não oficial, sem relação com a Pocketpair. Os mods pertencem aos seus autores e **não** são distribuídos neste repositório — o ModManager baixa cada um da fonte original.

## Funcionalidades

- **Instalação completa com um comando** — VC++ runtime, SteamCMD, servidor, configurações, firewall, mods e atalho na área de trabalho.
- **Configuração versionada** — você edita só `Config/*.json`; o `PalWorldSettings.ini` é gerado a cada start a partir do ini padrão do build atual, então opções novas de patches aparecem sozinhas.
- **ModManager** — instala, atualiza, remove, habilita/desabilita e faz rollback de mods do GitHub, Nexus ou arquivos locais, com dependências, hash, histórico das últimas 10 versões e rollback automático se uma instalação falhar.
- **Watchdog** — backup a cada 30 min, reinício diário às 05:00 com avisos no jogo, atualização automática do servidor e dos mods, reinício após crash, detecção de travamento e **modo seguro** (desliga os mods Lua se o servidor entrar em loop de crash).
- **Manutenção segura** — todo comando que mexe em arquivos de mod avisa os jogadores, salva, desliga, aplica e religa o servidor.
- **Painel gráfico** — status, jogadores, FPS e botões Iniciar / Parar / Backup / Atualizar mods.
- **Migração** — `Export.ps1` gera um pacote com mundo, segredos e mods baixados à mão; `Import.ps1` reconstrói tudo no PC novo.

## Requisitos

- Windows 10/11 x64, PowerShell 5.1 (já vem no Windows)
- [Git for Windows](https://git-scm.com/download/win)
- ~10 GB livres em disco e 8 GB+ de RAM
- Rodar a instalação **como Administrador** (VC++ runtime e regra de firewall)

## Instalação em um PC novo

```bash
git clone https://github.com/matheus013/PalHost.git C:\PalHost
```

Abra o PowerShell **como Administrador** e rode:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File C:\PalHost\Scripts\Install.ps1
```

O instalador cria `Config\server.config.json` a partir do exemplo e gera senhas aleatórias (servidor e admin) — ajuste depois conforme [docs/CONFIGURACAO.md](docs/CONFIGURACAO.md). Ao final, abra o atalho **PalHost Server** na área de trabalho e clique em **Iniciar**.

## Migrar de computador

No PC antigo:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File C:\PalHost\Scripts\Export.ps1
```

Leve o `.zip` gerado (em `Backups\Migration\`) para o PC novo, clone o repositório e rode como Administrador:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File C:\PalHost\Scripts\Import.ps1 -Package D:\PalHost-Migration_AAAAMMDD_HHMMSS.zip
```

Passo a passo completo, o que vai em cada lugar e cuidados: **[docs/MIGRACAO.md](docs/MIGRACAO.md)**.

## Uso diário

O jeito fácil é o painel: atalho **PalHost Server** na área de trabalho ou `PalHost-Painel.cmd`. Não dê duplo clique em arquivos `.ps1` — o Windows abre no editor em vez de executar.

Todos os comandos ficam em `Scripts\` e rodam com `powershell -NoProfile -ExecutionPolicy Bypass -File Scripts\<Comando>.ps1`:

| Comando | O que faz |
|---|---|
| `Start.ps1` | Sobe o servidor + watchdog (`-NoWatchdog` só sobe o processo) |
| `Stop.ps1` | Salva, avisa os jogadores e desliga (`-Force` mata na hora) |
| `Update.ps1` | Atualiza servidor e mods agora (também roda sozinho às 05:00) |
| `Backup.ps1` / `Restore.ps1` | Backup manual / lista e restaura backups (`-Latest`, `-BackupFile`) |
| `InstallMods.ps1` / `UpdateMods.ps1` | Instala ou atualiza mods (reinicia só se algo mudou) |
| `EnableMod.ps1` / `DisableMod.ps1` / `RemoveMod.ps1` | Liga, desliga ou remove um mod (`-Name X`) |
| `RollbackMod.ps1` | Volta um mod para uma das últimas 10 versões (`-Name X [-List]`) |
| `ListMods.ps1` | Estado de todos os mods |
| `BuildClientMods.ps1` | Gera o zip de mods para os jogadores (`-InstallToLocalGame` instala no seu jogo) |
| `Export.ps1` / `Import.ps1` | Migração de computador |
| `CreateShortcut.ps1` | Recria o atalho do painel na área de trabalho |

## Rede

| Porta | Protocolo | Abrir no roteador? |
|---|---|---|
| 8211 | UDP | **Sim** — porta do jogo |
| 8212 (REST API) | TCP | **Não** — controle local |
| 25575 (RCON) | TCP | **Não** — controle local |

Encaminhe **UDP 8211** no roteador para o IP local do servidor. Jogadores conectam em `SEU_IP_PUBLICO:8211`; no próprio PC, `127.0.0.1:8211`. Nunca exponha 8212/25575: a senha de admin dá controle total do servidor.

## Jogadores e mods do cliente

Alguns mods PAK precisam estar também no jogo de cada jogador, na mesma versão. Rode `BuildClientMods.ps1` e mande o `ClientMods-PalHost.zip` gerado na raiz do projeto — ele traz um `LEIA-ME.txt` com as instruções. Detalhes em [docs/MODS.md](docs/MODS.md#mods-do-cliente).

## Documentação

| Documento | Conteúdo |
|---|---|
| [docs/CONFIGURACAO.md](docs/CONFIGURACAO.md) | Referência de `server.config.json` e `world.settings.json`, rates atuais |
| [docs/MODS.md](docs/MODS.md) | ModManager, formato do `mods.json`, provedores, mods atuais e por que alguns estão desligados |
| [docs/MIGRACAO.md](docs/MIGRACAO.md) | Mudar o servidor de computador sem perder nada |
| [docs/ARQUITETURA.md](docs/ARQUITETURA.md) | Como o projeto funciona por dentro e como estendê-lo |
| [docs/SOLUCAO-DE-PROBLEMAS.md](docs/SOLUCAO-DE-PROBLEMAS.md) | Sintomas, causas e correções já vistos neste servidor |
| [CHANGELOG.md](CHANGELOG.md) | Histórico de mudanças |

## Estrutura

```
PalHost/
├── Config/                   # o que você edita (server.config.json fica fora do git)
├── Scripts/                  # comandos; Scripts/lib/ = Common.ps1 + ModManager.ps1
├── docs/                     # documentação
├── PalHost-Painel.cmd        # abre o painel
│   --- gerado na instalação (fora do git) ---
├── SteamCMD/  Server/        # ferramentas e servidor
├── Mods/                     # Installed, Cache, Nexus, GitHub, Local, Downloads
├── Saves/                    # atalho para Server\Pal\Saved\SaveGames
├── Backups/                  # backups do mundo e pacotes de migração
└── Logs/                     # logs por categoria e por dia
```
