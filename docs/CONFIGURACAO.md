# Configuração

Toda a configuração fica em `Config/`. **Nunca edite** `Server\Pal\Saved\Config\WindowsServer\PalWorldSettings.ini`: ele é regenerado a cada start (veja [ARQUITETURA.md](ARQUITETURA.md#geração-do-palworldsettingsini)).

| Arquivo | No git? | Conteúdo |
|---|---|---|
| `server.config.json` | **Não** (tem segredos) | Identidade, senhas, portas, backup, reinício, chave do Nexus |
| `server.config.example.json` | Sim | Modelo do arquivo acima; o `Install.ps1` copia se não existir |
| `world.settings.json` | Sim | Regras do mundo (rates, bases, drops...) |
| `mods.json` | Sim | Mods desejados — veja [MODS.md](MODS.md) |

Depois de mudar qualquer coisa: **Parar** e **Iniciar** no painel (ou `Stop.ps1` + `Start.ps1`).

## server.config.json

| Campo | Padrão | Descrição |
|---|---|---|
| `steam.appId` | `2394010` | App do servidor dedicado no Steam |
| `steam.steamCmdUrl` | URL oficial | De onde o SteamCMD é baixado |
| `server.name` / `server.description` | — | Nome e descrição exibidos no jogo |
| `server.port` / `server.publicPort` | `8211` | Porta UDP do jogo |
| `server.maxPlayers` | `16` | Máximo de jogadores |
| `server.serverPassword` | `CHANGE_ME` | Senha para entrar. `CHANGE_ME` → o instalador gera uma aleatória; `""` → **sem senha** |
| `server.adminPassword` | `CHANGE_ME` | Senha de admin (REST API, RCON, `/AdminPassword` no jogo). `CHANGE_ME` → gerada na instalação |
| `server.rconPort` / `server.restApiPort` | `25575` / `8212` | Controle local — não abra no roteador |
| `server.launchArgs` | flags de performance | Argumentos extras do `PalServer.exe` |
| `backup.intervalMinutes` | `30` | Intervalo do backup automático |
| `backup.retention` | `48` | Quantos backups automáticos manter |
| `backup.beforeUpdate` | `true` | Backup antes de cada atualização |
| `restart.dailyAt` | `05:00` | Horário do reinício diário |
| `restart.warningMinutes` | `[15, 5, 1]` | Avisos no jogo antes do reinício |
| `restart.autoUpdate` | `true` | Atualiza servidor e mods durante o reinício diário |
| `nexus.apiKey` | `""` | Chave pessoal do Nexus ([gerar aqui](https://www.nexusmods.com/users/myaccount?tab=api)). Download automático só funciona com conta Premium |
| `logs.retentionDays` | `14` | Por quantos dias manter logs |

Nome, senhas, portas e máximo de jogadores vêm **sempre** deste arquivo — eles sobrescrevem qualquer valor igual no `world.settings.json`.

## world.settings.json

Cada chave é uma opção do `OptionSettings` do Palworld, e o valor é escrito **literalmente** no ini. Regras:

- números com 6 casas: `"10.000000"`
- booleanos: `"True"` / `"False"`
- texto entre aspas dentro da string: `"\"meu texto\""`
- listas entre parênteses: `"(Steam,Xbox,PS5,Mac)"`
- chaves começando com `_` são comentários e são ignoradas

Opções que você não colocar ficam com o valor padrão do build atual (`Server\DefaultPalWorldSettings.ini` tem a lista completa). Se algum valor estiver malformado (parêntese ou aspas sem fechar), o start **recusa** gerar o ini e mostra qual opção corrigir — um ini quebrado faz o servidor travar sem mensagem nenhuma.

### Valores atuais

| Opção | Valor | Efeito |
|---|---|---|
| `ExpRate` | 10x | Experiência |
| `PalCaptureRate` | 2x | Chance de captura |
| `EnemyDropItemRate` | 10x | Drop de inimigos |
| `CollectionDropRate` | 10x | Recursos coletados (árvores, pedras, minérios) |
| `WorkSpeedRate` | 10x | Velocidade de trabalho dos Pals (fabricação, mineração, corte) |
| `MonsterFarmActionSpeedRate` | 10x | Produção do rancho |
| `PalEggDefaultHatchingTime` | 0 | Ovos chocam na hora |
| `PalStaminaDecreaceRate` | 0 | Stamina infinita dos Pals montados (voo/nado) |
| `DayTimeSpeedRate` / `NightTimeSpeedRate` | 1x / 1x | Duração do dia e da noite |
| `DeathPenalty` | `None` | Não perde itens ao morrer (`Item`, `ItemAndEquipment`, `All`) |
| `BaseCampMaxNumInGuild` | 10 | Bases por guilda |
| `BaseCampWorkerMaxNum` | 50 | Teto de Pals por base (o mod IncreasedBaseAndWorkers controla a progressão por nível) |
| `bEnableInvaderEnemy` | `False` | Sem raids |
| `DropItemMaxNum` | 2000 | Máximo de itens no chão no mundo (lag) |
| `PhysicsActiveDropItemMaxNum` | 300 | Máximo de itens com física ativa (maior ganho de FPS) |
| `DropItemAliveMaxHours` | 0.5 | Itens no chão somem após 30 min |
| `bAllowGlobalPalboxImport` / `Export` | `False` / `True` | Bloqueia Pals vindos de outros mundos |
| `bShowPlayerList` | `True` | Lista de jogadores no menu |
| `bIsUseBackupSaveData` | `True` | Backups internos do próprio jogo |
| `RCONEnabled` / `RESTAPIEnabled` | `True` | Necessários para os scripts (salvar, avisar, desligar, detectar travamento) |

> Não desligue o `RESTAPIEnabled`: sem ele os scripts não conseguem salvar/desligar com elegância e o watchdog perde a detecção de travamento.

### Observação sobre mundos existentes

Algumas opções são gravadas no `WorldOption.sav` quando o mundo é criado. Os rates e limites acima são aplicados a cada start; se alguma opção nova não fizer efeito num mundo antigo, é esse o motivo.
