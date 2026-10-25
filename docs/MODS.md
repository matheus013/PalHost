# Mods

O Palworld **não tem Steam Workshop**. No 1.0 o ecossistema é:

- **UE4SS** — framework que injeta Lua/C++ no servidor (`dwmapi.dll` + pasta `ue4ss\`);
- **PalSchema** — mods de dados em JSON, rodando em cima do UE4SS (server-side: jogadores não instalam nada);
- **mods PAK** — pacotes de assets em `Pal\Content\Paks\~mods\` (muitos precisam estar também no jogo de cada jogador).

O **ModManager** (`Scripts\lib\ModManager.ps1`) trata tudo isso como um gerenciador de pacotes: você declara o que quer em `Config\mods.json` e os comandos reconciliam o servidor com esse estado. Tudo é idempotente — rodar duas vezes não refaz nada.

## Comandos

| Comando | Função |
|---|---|
| `InstallMods.ps1 [-Name X] [-Force]` | Instala/sincroniza tudo (ou um mod) |
| `UpdateMods.ps1 [-Name X] [-NoRestart]` | Procura atualizações; só reinicia o servidor se algo mudou |
| `ListMods.ps1` | Estado de todos os mods (desejado × instalado) |
| `EnableMod.ps1 -Name X` / `DisableMod.ps1 -Name X` | Liga/desliga sem desinstalar |
| `RemoveMod.ps1 -Name X [-Force]` | Desinstala (recusa se outro mod depende dele) |
| `RollbackMod.ps1 -Name X [-List] [-BackupFile f]` | Volta para uma das últimas 10 versões |
| `BuildClientMods.ps1 [-InstallToLocalGame]` | Gera o zip para os jogadores |

Arquivos `.pak` e `.dll` ficam travados com o servidor rodando, então todo comando que precisa mudar arquivos **avisa no jogo, salva, desliga, aplica e religa** o servidor. Se nada mudou, o servidor não é tocado.

## Formato do mods.json

```json
{
  "name": "LessRestrictiveBuilding",
  "provider": "nexus",
  "modId": 98,
  "page": "https://www.nexusmods.com/palworld/mods/98",
  "installType": "pak",
  "enabled": true,
  "client": true,
  "dependsOn": [],
  "notes": "por que este mod está aqui / por que está desligado"
}
```

| Campo | Obrigatório | Descrição |
|---|---|---|
| `name` | sim | Identificador único; também é o nome da pasta em `Mods\Nexus\<name>\` |
| `provider` | sim | `github`, `nexus`, `local` ou `steam` (veja abaixo) |
| `enabled` | não (`true`) | `false` mantém o mod baixado mas fora do servidor |
| `dependsOn` | não | Mods instalados antes deste e que não podem ser removidos enquanto ele existir |
| `installType` | não | Força o tipo de instalação; sem ele o formato é detectado |
| `client` | não (`false`) | O jogador também precisa do mod → entra no `ClientMods-PalHost.zip` |
| `page` | não | Link para a página do mod (usado nas mensagens de log) |
| `notes` | não | Texto livre — use para registrar decisões |
| `modId` / `fileId` | nexus | ID do mod na URL do Nexus; `fileId` fixa uma variante específica |
| `repo` / `assetPattern` / `assetExclude` | github | `dono/repo` e curingas para escolher o arquivo do release |
| `path` | local | Zip, pak ou pasta (relativo à raiz do projeto ou absoluto) |
| `workshopId` | steam | Reservado para um eventual Workshop |

### Provedores

| Provider | Como baixa |
|---|---|
| `github` | Release mais recente do repositório, via API pública — **totalmente automático**. Cada tag é guardada em `Mods\GitHub\<name>\<tag>\`; sem internet, usa a última baixada |
| `nexus` | Com conta **Premium** e `nexus.apiKey`, baixa sozinho o arquivo principal mais novo (ou o `fileId`). Sem Premium, você baixa no site e solta o arquivo em `Mods\Nexus\<name>\` — o mais novo da pasta vale. O log mostra a versão disponível no Nexus |
| `local` | Usa o caminho em `path` |
| `steam` | SteamCMD `workshop_download_item` (para o futuro) |

### Tipos de instalação

| `installType` | Destino no servidor | Detectado quando o pacote tem |
|---|---|---|
| `gameroot` | raiz do servidor | pasta `Pal\Binaries` ou `Pal\Content` |
| `ue4ss` | `Pal\Binaries\Win64\` | `ue4ss\`, `dwmapi.dll` ou `UE4SS.dll` |
| `ue4ss-mod` | `Win64\ue4ss\Mods\<name>\` (+ `enabled.txt`) | `Scripts\main.lua` |
| `palschema` | `Win64\ue4ss\Mods\PalSchema\mods\<name>\` | só arquivos `.json` |
| `pak` | `Pal\Content\Paks\~mods\<name>\` | arquivos `.pak` |
| `logicmods` | `Pal\Content\Paks\LogicMods\` | `.pak` dentro de `LogicMods` |

Zips com uma pasta "embrulhando" o conteúdo são achatados automaticamente, e mods Lua com `Scripts\main.lua` dentro de uma subpasta são reposicionados. Arquivos `.rar`/`.7z` usam o `tar` do Windows (ou o 7-Zip, se instalado).

## Adicionar um mod

**Do GitHub** — adicione a entrada com `provider: "github"`, `repo` e `assetPattern`, depois rode `InstallMods.ps1`.

**Do Nexus, sem Premium:**

1. abra a aba *Files* do mod e baixe o arquivo principal (**Manual Download → Slow Download**);
2. crie a entrada no `mods.json` (`provider: "nexus"`, `modId`);
3. solte o arquivo, sem extrair, em `Mods\Nexus\<name>\`;
4. rode `InstallMods.ps1` (ou `EnableMod.ps1 -Name <name>`).

Para atualizar depois, baixe a versão nova para a mesma pasta e rode `UpdateMods.ps1`.

**Antes de adicionar**, confira a data do último update do mod: mods feitos para uma versão anterior do jogo costumam travar ou derrubar o servidor depois de um patch (veja [SOLUCAO-DE-PROBLEMAS.md](SOLUCAO-DE-PROBLEMAS.md)).

## Backups, rollback e segurança

- Antes de cada atualização ou remoção, a versão atual vai para `Mods\Cache\Backups\<name>\` (últimas 10).
- Se a instalação falhar no meio, o mod volta sozinho para a versão anterior.
- `Mods\Installed\registry.json` guarda, por mod: versão, provedor, tipo, hash da origem e do conteúdo, datas de instalação/atualização, estado, arquivos implantados e o build do servidor na hora da instalação.

## Mods do cliente

Mods com `"client": true` precisam estar no jogo de cada jogador, na **mesma versão** do servidor. Depois de instalar ou atualizar um deles:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File Scripts\BuildClientMods.ps1 -InstallToLocalGame
```

Isso gera `ClientMods-PalHost.zip` na raiz (com `LEIA-ME.txt`) e, com `-InstallToLocalGame`, atualiza o seu próprio jogo (feche o jogo antes). Peça aos jogadores para **apagar** a pasta `~mods` antiga antes de copiar a nova.

## Mods configurados

| Mod | Origem | Estado | Observação |
|---|---|---|---|
| UE4SS (RE-UE4SS Experimental-Palworld) | GitHub `Okaetsu/RE-UE4SS` | ativo | Framework |
| PalSchema | GitHub `Okaetsu/PalSchema` | ativo | Cada release diz qual build do UE4SS exige |
| MapUnlocker | Nexus 16 | ativo | Mapa revelado |
| LessRestrictiveBuilding | Nexus 98 | ativo · cliente | Construção sem restrições. Só a **1.6.1+** funciona no jogo 1.0.4+ |
| IncreasedBaseAndWorkers (variante x2) | Nexus 55 (`fileId` 354) | ativo · cliente | +1 base e +2 Pals por nível de base |
| StackSizeIncrease (ChickNomad) | Nexus 3899 | ativo | Stacks maiores |
| CarryWeightIncrease | Nexus 11 | ativo | Peso 1000, +250 por ponto |
| FasterBreeding | Nexus 2565 | ativo | Ovo a cada ~60 s no rancho (PalSchema) |
| CombineDrops 2.0 | Nexus 4575 | ativo | Junta drops iguais no chão — compensa o drop 10x |
| InfiniteStaminaFlying | Nexus 13 | desligado | Redundante com `PalStaminaDecreaceRate=0` |
| AutoPickup | Nexus 3430 | desligado | Suspeito de crashes em jul/ago 2026 |
| StuckPalRescuer | Nexus 585 | desligado | Mod de 2024, suspeito de crashes |
| AdminCommands | Nexus 2371 | desligado | Desnecessário num servidor de amigos |
| PalServerSettings | Nexus 4166 | desligado | O ini gerado já aplica tudo |
| BetterPalbox (Palbox Sorter) | Nexus 3987 | desligado · cliente | Mod de interface; cada jogador instala se quiser |

O campo `notes` de cada entrada no `mods.json` registra o motivo detalhado.

## Regras de compatibilidade aprendidas

- **UE4SS vem do GitHub do Okaetsu.** A página do Nexus (3035) foi ocultada em 2026; o pacote antigo "UE4SS Prepackaged" (Nexus 1121) é anterior ao 1.0 e derruba o servidor quando alguém entra.
- **UE4SS e PalSchema andam juntos.** Atualize os dois ao mesmo tempo (o `UpdateMods.ps1` faz isso).
- **Patch do jogo = conferir os PAKs.** Um PAK antigo não costuma crashar: ele **trava** o servidor no boot, sem log. Foi o caso do LessRestrictiveBuilding 1.5.x no jogo 1.0.5.
- **Mods de primeira versão são arriscados.** O CombineDrops 1.0 crashava após 15–45 min; a 2.0 corrigiu e adicionou suporte a servidor.
