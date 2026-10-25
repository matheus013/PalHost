# Migração para outro computador

A migração tem duas partes porque nem tudo pode ir para um repositório público:

| Onde | O quê |
|---|---|
| **GitHub** (este repositório) | Scripts, documentação, `mods.json`, `world.settings.json`, `server.config.example.json` |
| **Pacote de migração** (`Export.ps1`) | O **mundo** (saves dos jogadores, bases, Pals), o `server.config.json` real (senhas, chave do Nexus), as versões atuais dos `Config/*.json` e os **arquivos de mods baixados manualmente** do Nexus |
| **Baixado de novo** no PC novo | SteamCMD, servidor, VC++ runtime e mods que vêm do GitHub (UE4SS, PalSchema) |

> O pacote contém a senha de admin e a chave da API do Nexus. Guarde-o como um documento pessoal (pendrive, pasta privada na nuvem) e **nunca** o coloque no repositório.

## 1. No computador antigo

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File C:\PalHost\Scripts\Export.ps1
```

- Pode rodar com o servidor ligado: ele pede ao servidor para salvar antes de copiar.
- O pacote sai em `Backups\Migration\PalHost-Migration_<data>.zip` (ou onde você indicar com `-OutFile`).
- Se os amigos estiverem jogando, avise antes: tudo que acontecer **depois** do export não vai para o PC novo.

Depois do export, **pare o servidor antigo** (`Stop.ps1`) e não ligue mais: dois servidores com o mesmo mundo divergem e não há como juntar.

## 2. No computador novo

1. Instale o [Git for Windows](https://git-scm.com/download/win).
2. Clone o projeto:

```bash
git clone https://github.com/matheus013/PalHost.git C:\PalHost
```

3. Copie o pacote para o PC novo e rode **como Administrador**:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File C:\PalHost\Scripts\Import.ps1 -Package D:\PalHost-Migration_AAAAMMDD_HHMMSS.zip
```

O `Import.ps1`:

1. restaura os `Config/*.json` do pacote (se já existir um diferente, guarda o anterior como `.bak`);
2. restaura os arquivos de mods do Nexus/locais;
3. roda o `Install.ps1` completo — VC++ runtime, SteamCMD, servidor (~6 GB), configurações, firewall, mods e atalho na área de trabalho;
4. restaura o mundo (com o mesmo identificador, então o servidor carrega o mundo antigo, não um novo).

É seguro rodar de novo se algo falhar no meio (por exemplo, queda de internet durante o download do servidor).

4. Inicie pelo atalho **PalHost Server** e confira no painel que o servidor ficou **ONLINE**.
5. No roteador, mova o encaminhamento de **UDP 8211** para o IP local do PC novo e passe o novo IP público aos jogadores (se mudou).
6. Se você também joga neste PC: `Scripts\BuildClientMods.ps1 -InstallToLocalGame` (com o jogo fechado).

## Opções

| Parâmetro | Uso |
|---|---|
| `Export.ps1 -OutFile <caminho>` | Salva o pacote direto num pendrive, por exemplo |
| `Import.ps1 -SkipFirewall` | Não cria a regra de firewall |
| `Import.ps1 -SkipShortcut` | Não cria o atalho na área de trabalho |
| `Import.ps1 -RegisterAutoStart` | Inicia o servidor automaticamente no logon |

## Migração manual (sem o Export)

Se o PC antigo não liga mais mas o disco está acessível, dá para montar a migração à mão no PC novo:

1. clone o repositório e copie `Config\server.config.json` do disco antigo para `Config\`;
2. copie o backup mais recente de `Backups\PalSaves_*.zip` para `Backups\` do PC novo;
3. copie as pastas de `Mods\Nexus\` (mods que não baixam sozinhos);
4. rode `Install.ps1` e depois `Restore.ps1 -Latest`.

Sem nenhum backup, copie a pasta `Server\Pal\Saved\` inteira do disco antigo para o mesmo lugar no PC novo depois do `Install.ps1`.

## Validação

Em 25/10/2026 o `Export.ps1` foi testado com o servidor online (com um jogador conectado): o pacote saiu com 12,8 MB contendo o mundo (`Level.sav` + `GameUserSettings.ini` com o identificador do mundo), os quatro `Config/*.json` e os 14 arquivos de mods. O `Import.ps1` ainda **não** foi ensaiado de ponta a ponta (o ensaio exige desligar o servidor real, porque as duas cópias usariam as mesmas portas). Até lá, guarde também o backup mais recente de `Backups\` — com ele a [migração manual](#migração-manual-sem-o-export) sempre funciona.

> Um computador só roda um servidor PalHost por vez: os scripts identificam o servidor pelo nome do processo e pelas portas 8211/8212.
