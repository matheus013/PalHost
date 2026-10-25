# Solução de problemas

Cada item abaixo aconteceu de verdade neste servidor. Onde olhar primeiro:

| Fonte | Caminho |
|---|---|
| Logs dos scripts | `Logs\Server\`, `Logs\Mods\`, `Logs\Update\`, `Logs\Backup\` |
| Crash dumps do jogo | `Server\Pal\Saved\Crashes\` (o `CrashContext.runtime-xml` mostra a mensagem e se o UE4SS está na pilha) |
| Log do UE4SS | `Server\Pal\Binaries\Win64\ue4ss\UE4SS.log` (quais mods carregaram) |
| SteamCMD | `Logs\Update\steamcmd-last-run.log` |

**Método que sempre funciona para achar o culpado:** suba o servidor *vanilla* (`DisableMod.ps1` no UE4SS e nos PAKs) e confira se ele fica ONLINE. Depois religue os mods em grupos (PAKs, depois UE4SS + Lua) até o problema voltar.

---

### O servidor fecha sozinho logo ao iniciar, sem log nenhum
**Causa:** falta o Visual C++ Redistributable x64.
**Correção:** o `Install.ps1` instala sozinho quando roda como Administrador; ou instale manualmente [vc_redist.x64.exe](https://aka.ms/vs/17/release/vc_redist.x64.exe).

### O servidor "liga", mas nunca aceita conexão (0% de CPU, sem porta 8211, sem crash dump)
**Causas já vistas:**
1. **`PalWorldSettings.ini` malformado** — aconteceu no patch 1.0.4/1.0.5 com a lista `CrossplayPlatforms=(...)`. Corrigido no parser; hoje o start recusa gravar um ini quebrado e diz qual opção corrigir.
2. **Mod PAK de uma versão anterior do jogo** — LessRestrictiveBuilding 1.5.x travava o 1.0.5; a 1.6.1 resolveu.

**Correção:** desligue os PAKs com `DisableMod.ps1` e teste. O watchdog mata um servidor travado após 10 minutos e, após dois travamentos seguidos no boot, entra em modo seguro.

### Crash quando alguém entra no servidor
**Causa:** UE4SS desatualizado para o build do jogo (o pacote antigo do Nexus 1121, anterior ao 1.0).
**Correção:** usar o UE4SS do GitHub do Okaetsu (já configurado) e rodar `UpdateMods.ps1` após cada patch.

### Crashes periódicos durante o jogo (`EXCEPTION_ACCESS_VIOLATION` com UE4SS na pilha)
**Causas já vistas:** CombineDrops 1.0 (corrigido na 2.0), suspeita sobre AutoPickup e StuckPalRescuer, e bugs de FText no UE4SS de julho (corrigidos no `2281fa31`).
**Correção:** `UpdateMods.ps1`; se persistir, desligue os mods Lua mais recentes um a um.

### O painel mostra MODO SEGURO
O watchdog desligou o UE4SS depois de um loop de crash ou de travamentos no boot (o motivo está em `Logs\Server\`). Normalmente é um patch do jogo que quebrou o UE4SS/PalSchema. Rode `UpdateMods.ps1` e depois `EnableMod.ps1 -Name UE4SS`.

### "Versão incompatível" ao conectar
O Steam atualizou o jogo dos jogadores e o servidor ainda não. Rode `Update.ps1` (ou espere o auto-update das 05:00).

### Atualização de mod falhou com "arquivo sendo usado por outro processo"
Arquivos `.pak`/`.dll` ficam travados com o servidor ligado. Os comandos atuais desligam o servidor antes; se aparecer de novo, confira se não há outra cópia do servidor rodando.

### Backups em dobro / servidor religando sozinho no meio de uma manutenção
**Causa:** dois watchdogs rodando ao mesmo tempo.
**Correção:** já resolvido com a trava `.watchdog.pid`. Para conferir: `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -match 'Start\.ps1'` deve mostrar no máximo um processo.

### Duplo clique no Launcher.ps1 abre o VS Code
O Windows não executa `.ps1` com duplo clique — abre no editor padrão. Use o atalho **PalHost Server** (`CreateShortcut.ps1` recria) ou o `PalHost-Painel.cmd`.

### O download automático do Nexus parou ("Auto-download needs Premium")
A conta Premium expirou. Baixe o arquivo na aba *Files* do mod (**Manual Download → Slow Download**) e solte em `Mods\Nexus\<NomeDoMod>\` — veja [MODS.md](MODS.md#adicionar-um-mod).

### SteamCMD não instala o servidor na primeira vez
Na primeira execução o SteamCMD só se atualiza e ignora os comandos. O `Install.ps1` já faz uma rodada de "aquecimento" e tenta de novo; se falhar, rode o `Install.ps1` outra vez.

### Mods do cliente: o jogo dos jogadores trava ou constrói diferente do servidor
Algum jogador está com um PAK de versão diferente. Gere o zip de novo (`BuildClientMods.ps1`) e peça para **apagar** a pasta `~mods` antiga antes de copiar a nova.
