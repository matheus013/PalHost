# Changelog

## 2026-10-25 — Revisão para o Palworld 1.0.5 + GitHub

### Jogo e mods
- Servidor atualizado do build de julho para o **1.0.5** (patch de 15/09/2026).
- **UE4SS** migrado para o GitHub `Okaetsu/RE-UE4SS` (release `2281fa31`, corrige crashes de FText); a página do Nexus foi ocultada.
- **PalSchema** 0.6.71 migrado para o GitHub `Okaetsu/PalSchema` (par obrigatório do UE4SS `2281fa31`).
- **LessRestrictiveBuilding** 1.6.1 — a 1.5.x travava o servidor no 1.0.5.
- **CombineDrops** 2.0 reativado (suporte a servidor e correção de crashes).
- InfiniteStaminaFlying desligado (redundante com `PalStaminaDecreaceRate=0`).
- Drop de inimigos e coleta em **10x** (produção já estava em 10x).

### Correções
- Parser do ini quebrava `CrossplayPlatforms=(Steam,Xbox,PS5,Mac)` (nova no 1.0.4) e o servidor travava no boot; agora o parser respeita parênteses e o ini é validado antes de ser gravado.
- Atualizar mods com o servidor ligado deixava PAKs instalados pela metade (03/08); todos os comandos de mod agora desligam/religam o servidor com aviso.
- Trava do watchdog agora é adquirida antes de subir o servidor e verificada pela linha de comando do processo (PIDs reaproveitados após reboot).
- Uso de `$args` (variável automática) removido do `Start.ps1`.

### Novidades
- Provedor `github` no ModManager.
- Rollback automático se uma instalação de mod falhar no meio.
- Atualização automática do servidor e dos mods no reinício das 05:00 (`restart.autoUpdate`).
- Detecção de travamento (10 min sem resposta) e **modo seguro** (3 crashes em 10 min ou 2 travamentos no boot).
- Painel mostra MODO SEGURO.
- `Export.ps1` / `Import.ps1` para migrar o servidor de computador.
- `BuildClientMods.ps1` (zip para os jogadores, campo `client` no `mods.json`) e `CreateShortcut.ps1`.
- `Install.ps1` instala o VC++ runtime e cria o config a partir de `server.config.example.json`.
- Projeto publicado no GitHub com documentação em `docs/`.

## 2026-08-03
- Desligados AutoPickup e StuckPalRescuer: crashes caíram de 11 (julho) para 1 (agosto).

## 2026-07-31 — Primeira versão
- Instalação automática (SteamCMD + servidor), configuração em JSON, backups, reinício diário, watchdog, painel WinForms.
- ModManager com provedores Nexus/local/steam, dependências, histórico de versões e rollback.
- Migração do UE4SS "Prepackaged" (Nexus 1121) para o RE-UE4SS experimental após crashes ao entrar no servidor.
- Limites de itens no chão (2000 / 300 com física / 30 min) e variante x2 do IncreasedBaseAndWorkers.
- Senha do servidor removida e importação de Pals de outros mundos bloqueada.
