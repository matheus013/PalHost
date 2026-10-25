# Arquitetura

O projeto é PowerShell 5.1 puro, sem dependências externas além do SteamCMD. Os scripts de `Scripts\` são finos: cada um faz *dot-source* de duas bibliotecas e chama funções delas.

```
Scripts\
├── lib\Common.ps1       caminhos, log, config, geração do ini, REST API,
│                        controle do processo, SteamCMD, manutenção segura
├── lib\ModManager.ps1   gerenciador de mods (depende do Common.ps1)
├── Start.ps1            servidor + watchdog
├── Stop.ps1, Update.ps1, Backup.ps1, Restore.ps1
├── *Mod*.ps1            comandos do ModManager
├── Export.ps1, Import.ps1, BuildClientMods.ps1, CreateShortcut.ps1, Install.ps1
└── Launcher.ps1         painel WinForms
```

Convenções: comentários em inglês, mensagens ao usuário em português no painel e nos docs, `Set-StrictMode -Version Latest` e `$ErrorActionPreference = 'Stop'` em tudo, caminhos sempre derivados da posição do `Common.ps1` (o projeto funciona em qualquer pasta).

## Estados em disco

| Arquivo | Dono | Função |
|---|---|---|
| `Config\*.json` | usuário | Estado desejado |
| `Mods\Installed\registry.json` | ModManager | Estado instalado dos mods |
| `Mods\Installed\<name>\` | ModManager | Cópia canônica de cada mod |
| `.watchdog.pid` | Start.ps1 | Trava de instância única do watchdog |
| `.stop-requested` | Stop/manutenção | Diz ao watchdog para não ressuscitar o servidor |
| `Logs\<Categoria>\AAAA-MM-DD.log` | todos | `Install`, `Update`, `Server`, `Backup`, `Mods`, `Migration` |

## Geração do PalWorldSettings.ini

`Build-PalWorldSettings` roda a cada start:

1. lê `Server\DefaultPalWorldSettings.ini` **do build instalado** — opções novas de patches entram automaticamente com o valor padrão;
2. aplica por cima `Config\world.settings.json` (valores literais);
3. aplica identidade, senhas e portas de `Config\server.config.json` (fonte única desses campos);
4. valida cada valor (`Test-OptionValue`: parênteses e aspas balanceados) e **recusa** gravar se algo estiver quebrado;
5. grava `Server\Pal\Saved\Config\WindowsServer\PalWorldSettings.ini`.

O parser (`Split-OptionSettings`) divide o `OptionSettings=(...)` só nas vírgulas de nível zero, fora de aspas e de parênteses. Isso importa: desde o patch 1.0.4 existe `CrossplayPlatforms=(Steam,Xbox,PS5,Mac)`, e um split ingênuo por vírgula gera um ini que faz o servidor travar no boot sem nenhuma mensagem.

## REST API

Os scripts conversam com o servidor pela REST API oficial (`http://127.0.0.1:8212/v1/api/`, autenticação Basic `admin:<adminPassword>`), via `Invoke-PalApi`:

| Endpoint | Uso |
|---|---|
| `info` | Health check (boot concluído, servidor respondendo) |
| `metrics` | Painel: jogadores, FPS, uptime, dia |
| `save` | Antes de backups e desligamentos |
| `announce` | Avisos no chat (reinício, manutenção) |
| `shutdown` | Desligamento gracioso com contagem |

Sem a API, o desligamento cai para `Stop-Process` e o watchdog perde a detecção de travamento.

## Watchdog (Start.ps1)

```
Start.ps1
 ├─ trava .watchdog.pid (sai se outro watchdog vivo — verificado pela linha de comando do processo)
 ├─ sobe o servidor (ou se acopla a um que já está rodando)
 └─ laço a cada 20 s:
     ├─ .stop-requested + servidor parado  → remove a trava e sai
     ├─ processo morreu                    → registra crash, religa
     │    └─ 3 crashes em 10 min           → MODO SEGURO
     ├─ API sem responder há 10 min        → considera travado, mata o processo
     │    └─ 2 travamentos seguidos no boot → MODO SEGURO
     ├─ a cada 30 min                      → Backup.ps1
     └─ 05:00 (avisos aos 15/5/1 min)      → backup, desliga,
                                             [autoUpdate: SteamCMD + Sync-PalMods], religa
```

**Modo seguro** = `Set-PalModEnabled UE4SS $false`: o UE4SS e, com ele, todos os mods Lua/PalSchema param de carregar; os PAKs continuam. Fica registrado no `mods.json` (o painel mostra **MODO SEGURO**) até alguém rodar `EnableMod.ps1 -Name UE4SS`.

## Manutenção segura

`Invoke-WithServerStopped -Action { ... }` é usado por todo comando que mexe em arquivos do servidor:

1. se o servidor está rodando: aviso no chat, espera (30–60 s), cria `.stop-requested`, `save` + `shutdown` pela API;
2. espera o watchdog perceber e sair (`Wait-PalWatchdogExit`), para ele não religar o servidor no meio;
3. executa a ação;
4. no `finally`: remove `.stop-requested` e sobe um watchdog novo — mesmo se a ação falhou.

O `ModManager` reforça isso com `Assert-PalServerStopped`: qualquer função que altera arquivos implantados recusa rodar com o servidor ligado.

## ModManager

Modelo de três camadas, como um gerenciador de pacotes:

```
mods.json (desejado) ──Get-ModPayload──> arquivo de origem (cache por provedor)
                                              │ hash ≠ registry.sourceHash ?
                                              ▼
                     Expand-ModPayload → staging → detecção do tipo
                                              ▼
                     Mods\Installed\<name>\ (cópia canônica) ──Deploy──> Server\...
                                              ▼
                     registry.json (versão, hashes, arquivos implantados, build)
```

- **Idempotência:** compara o hash do arquivo de origem com `sourceHash` no registro; igual → nada a fazer (só reconcilia ligado/desligado).
- **Dependências:** ordenação topológica (`Resolve-ModInstallOrder`), com detecção de ciclo; dependências faltando são instaladas antes; remoção é bloqueada se houver dependentes.
- **Deploy/undeploy:** os arquivos implantados ficam listados no registro, então desinstalar remove exatamente o que foi colocado e limpa pastas vazias.
- **Atualização segura:** backup da cópia canônica antes; se a troca falhar, `Restore-ModBackup` volta a versão anterior.
- **Verificação sem efeitos:** `Get-PalModPendingChanges` baixa novidades para o cache e diz o que mudaria, sem tocar no servidor — é ele que decide se vale reiniciar.

### Estendendo

**Novo provedor:** escreva `Get-<X>Payload -Mod $mod` retornando `@{ Path; Version; Hash }` (ou `$null` se não houver arquivo) e adicione ao `switch` de `Get-ModPayload`.

**Novo tipo de instalação:** adicione o destino em `Get-ModTargetRoot` e, se quiser detecção automática, a regra em `Get-ModInstallType`.

## Migração

`Export.ps1` empacota o que não está no git (mundo via `Backup.ps1`, `Config\*.json`, arquivo mais novo de cada `Mods\Nexus\<name>\`, `Mods\Local\`) com um `manifest.json`. `Import.ps1` restaura configs e arquivos de mods, roda o `Install.ps1` (que recria todo o resto) e por fim o `Restore.ps1`. O backup do mundo inclui `GameUserSettings.ini`, cujo `DedicatedServerName` aponta para o mundo — por isso o servidor novo carrega o mundo antigo e não cria outro.
