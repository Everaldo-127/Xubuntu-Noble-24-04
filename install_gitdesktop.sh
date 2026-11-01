#!/usr/bin/env bash
# GitHub Manager Desktop V7.1 — instalador autônomo para Linux.
# Todo o código Bash e Python do aplicativo está incorporado neste arquivo.
# Fluxo: diagnóstico -> instalação -> validação -> backup/rollback -> criação.
# Tarefas executadas na janela principal; perguntas e resultados ficam incorporados à interface.
set -Eeuo pipefail
umask 077

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  printf 'Execute como usuário normal, sem iniciar o instalador com sudo.\n' >&2
  exit 1
fi

APP_TITLE='GitHub Manager — GIT LOCAL'
[[ -n "${HOME:-}" && "$HOME" == /* && "$HOME" != "/" && -d "$HOME" ]] || { printf 'ERRO: HOME inválido.\n' >&2; exit 1; }
HOME_PHYSICAL="$(cd -- "$HOME" 2>/dev/null && pwd -P)" || exit 1
[[ "$HOME_PHYSICAL" == "$HOME" ]] || { printf 'ERRO: HOME contém link simbólico; use o caminho físico.\n' >&2; exit 1; }
for protected_dir in "$HOME/.local" "$HOME/.local/share" "$HOME/.local/state" "$HOME/.local/share/applications"; do
  [[ ! -L "$protected_dir" ]] || { printf 'ERRO: caminho protegido é link simbólico: %s\n' "$protected_dir" >&2; exit 1; }
done
BASE="$HOME/.local/share/github-manager"
APP="$BASE/github-manager.sh"
GUI="$BASE/github-manager-gui.py"
APP_ENTRY="$HOME/.local/share/applications/GitHub-Manager.desktop"
[[ ! -L "$BASE" && ! -L "$APP_ENTRY" ]] || { printf 'ERRO: instalação/atalho é link simbólico.\n' >&2; exit 1; }
if command -v xdg-user-dir >/dev/null 2>&1; then DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"; else DESKTOP_DIR=''; fi
[[ -n "$DESKTOP_DIR" ]] || DESKTOP_DIR="$HOME/Desktop"
[[ "$DESKTOP_DIR" == /* && "$DESKTOP_DIR" != "/" && ! -L "$DESKTOP_DIR" ]] || {
  printf 'ERRO: diretório da Área de Trabalho inválido ou link simbólico.\n' >&2
  exit 1
}
if [[ -d "$DESKTOP_DIR" ]]; then
  DESKTOP_DIR="$(cd -- "$DESKTOP_DIR" 2>/dev/null && pwd -P)" || exit 1
fi
DESKTOP_ENTRY="$DESKTOP_DIR/GitHub-Manager.desktop"

say() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }
have_tkinter() { command -v python3 >/dev/null 2>&1 && python3 -c 'import tkinter, tkinter.ttk, urllib.request, json, threading, subprocess' >/dev/null 2>&1; }
version_at_least() {
  local actual="$1" required="$2" first
  command -v sort >/dev/null 2>&1 || return 1
  first="$(printf '%s\n%s\n' "$actual" "$required" | sort -V | head -n1)"
  [[ "$first" == "$required" ]]
}
command_version() {
  case "$1" in
    python3) python3 --version 2>&1 | awk '{print $2}' ;;
    curl) curl --version 2>/dev/null | head -n1 | awk '{print $2}' ;;
    jq) jq --version 2>/dev/null | sed 's/^jq-//' ;;
    zenity) zenity --version 2>/dev/null | head -n1 ;;
    git) git --version 2>/dev/null | awk '{print $3}' ;;
    *) printf '0' ;;
  esac
}

say 'ETAPA 1/4 — Diagnóstico da distribuição, programas e versões.'
[[ -r /etc/os-release ]] && . /etc/os-release || true
DISTRO="${PRETTY_NAME:-Linux não identificado}"
printf 'Sistema: %s\n' "$DISTRO"
printf 'Arquitetura: %s\n' "$(uname -m)"
printf 'Usuário: %s\n' "${USER:-$(id -un)}"

PM=''; PACKAGES=(); UPDATE=(); INSTALL=()
if command -v apt-get >/dev/null 2>&1; then
  PM=apt; PACKAGES=(python3 python3-tk curl jq git coreutils diffutils findutils tar gzip zenity); UPDATE=(apt-get update); INSTALL=(apt-get install -y)
elif command -v dnf >/dev/null 2>&1; then
  PM=dnf; PACKAGES=(python3 python3-tkinter curl jq git coreutils diffutils findutils tar gzip zenity); UPDATE=(dnf makecache); INSTALL=(dnf install -y)
elif command -v yum >/dev/null 2>&1; then
  PM=yum; PACKAGES=(python3 python3-tkinter curl jq git coreutils diffutils findutils tar gzip zenity); UPDATE=(); INSTALL=(yum install -y)
elif command -v pacman >/dev/null 2>&1; then
  PM=pacman; PACKAGES=(python tk curl jq git coreutils diffutils findutils tar gzip zenity); UPDATE=(); INSTALL=(pacman -S --needed --noconfirm)
elif command -v zypper >/dev/null 2>&1; then
  PM=zypper; PACKAGES=(python3 python3-tk curl jq git coreutils diffutils findutils tar gzip zenity); UPDATE=(zypper --non-interactive refresh); INSTALL=(zypper --non-interactive install -y)
elif command -v apk >/dev/null 2>&1; then
  PM=apk; PACKAGES=(python3 py3-tkinter curl jq git coreutils diffutils findutils tar gzip zenity); UPDATE=(apk update); INSTALL=(apk add --no-cache)
else
  fail 'Gerenciador de pacotes não reconhecido. Compatíveis: apt, dnf, yum, pacman, zypper e apk. Instalação interrompida sem alterar o aplicativo.'
fi
printf 'Gerenciador de pacotes: %s\n' "$PM"

if command -v sudo >/dev/null 2>&1; then PRIV=(sudo)
elif command -v doas >/dev/null 2>&1; then PRIV=(doas)
else PRIV=(); fi
MIN_PYTHON='3.8'; MIN_CURL='7.60.0'; MIN_JQ='1.5'; MIN_GIT='2.20.0'
missing=0
for c in python3 curl jq git tar gzip zenity diff cmp find base64; do command -v "$c" >/dev/null 2>&1 || { printf '  AUSENTE: %s\n' "$c"; missing=1; }; done
have_tkinter || { printf '  AUSENTE/INOPERANTE: Python Tkinter ou módulos da biblioteca padrão\n'; missing=1; }
for spec in "python3:$MIN_PYTHON" "curl:$MIN_CURL" "jq:$MIN_JQ" "git:$MIN_GIT"; do
  c="${spec%%:*}"; req="${spec#*:}"
  if command -v "$c" >/dev/null 2>&1; then
    got="$(command_version "$c" || true)"
    if ! version_at_least "$got" "$req"; then printf '  VERSÃO INSUFICIENTE: %s atual=%s mínimo=%s\n' "$c" "${got:-desconhecida}" "$req"; missing=1
    else printf '  OK: %s %s (mínimo %s)\n' "$c" "$got" "$req"; fi
  fi
done
if (( missing )); then
  ((${#PRIV[@]})) || fail 'Faltam dependências/versões e não há sudo/doas. Nenhum arquivo do aplicativo foi alterado.'
  say "Instalando dependências pelo gerenciador $PM."
  if ((${#UPDATE[@]})); then "${PRIV[@]}" "${UPDATE[@]}" || fail 'Falha ao atualizar os índices de pacotes. O aplicativo ainda não foi alterado.'; fi
  "${PRIV[@]}" "${INSTALL[@]}" "${PACKAGES[@]}" || fail 'Falha ao instalar dependências. O aplicativo ainda não foi alterado.'
fi

say 'Revalidando dependências e versões mínimas.'
for c in python3 curl jq git tar gzip zenity diff cmp find base64; do command -v "$c" >/dev/null 2>&1 || fail "Dependência ausente após instalação: $c"; done
have_tkinter || fail 'Tkinter ou módulos Python necessários não funcionam após a instalação.'
for spec in "python3:$MIN_PYTHON" "curl:$MIN_CURL" "jq:$MIN_JQ" "git:$MIN_GIT"; do
  c="${spec%%:*}"; req="${spec#*:}"; got="$(command_version "$c" || true)"
  version_at_least "$got" "$req" || fail "Versão insuficiente para $c: atual=${got:-desconhecida}; mínimo=$req. Nenhum arquivo do aplicativo foi alterado."
done
python3 -c 'import tkinter, tkinter.ttk, urllib.request, json, threading, subprocess; print("Python/Tkinter: importação funcional.")' || fail 'Falha no teste funcional de Python/Tkinter.'

say 'ETAPA 2/4 — Criando backup de rollback antes de criar/substituir o programa.'
STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_ROOT="$HOME/.local/state/github-manager-backups"
[[ ! -L "$BACKUP_ROOT" ]] || fail 'A pasta de backups é um link simbólico. Operação bloqueada.'
mkdir -p "$BACKUP_ROOT" || fail 'Não foi possível preparar a pasta de backups.'
BACKUP="$(mktemp -d "$BACKUP_ROOT/$STAMP.XXXXXXXX")" || fail 'Não foi possível criar uma pasta exclusiva para o backup.'
chmod 700 "$BACKUP" || fail 'Não foi possível proteger as permissões do backup.'
mkdir -m 700 "$BACKUP/original" || fail 'Não foi possível criar a pasta original do backup.'
{
  printf 'Data: %s\nDistribuição: %s\nGerenciador: %s\n' "$(date -Is 2>/dev/null || date)" "$DISTRO" "$PM"
  for c in python3 curl jq git; do printf '%s: %s\n' "$c" "$(command_version "$c" 2>/dev/null || echo ausente)"; done
} > "$BACKUP/ambiente.txt"
if command -v dpkg-query >/dev/null 2>&1; then dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$BACKUP/pacotes-instalados.txt" 2>/dev/null || true
elif command -v rpm >/dev/null 2>&1; then rpm -qa > "$BACKUP/pacotes-instalados.txt" 2>/dev/null || true
elif command -v pacman >/dev/null 2>&1; then pacman -Q > "$BACKUP/pacotes-instalados.txt" 2>/dev/null || true
elif command -v apk >/dev/null 2>&1; then apk info -vv > "$BACKUP/pacotes-instalados.txt" 2>/dev/null || true
fi
had_base=0; had_desktop=0; had_app_entry=0
[[ ! -L "$BASE" && ! -L "$DESKTOP_ENTRY" && ! -L "$APP_ENTRY" ]] || fail 'Link simbólico detectado em caminho que seria copiado/substituído.'
if [[ -e "$BASE" ]]; then
  [[ -d "$BASE" ]] || fail 'O caminho da instalação existe, mas não é diretório.'
  had_base=1
  cp -a -- "$BASE" "$BACKUP/original/github-manager" || fail 'Não foi possível copiar a instalação anterior.'
fi
if [[ -e "$DESKTOP_ENTRY" ]]; then
  [[ -f "$DESKTOP_ENTRY" ]] || fail 'O atalho da Área de Trabalho não é arquivo regular.'
  had_desktop=1
  cp -a -- "$DESKTOP_ENTRY" "$BACKUP/original/Desktop-GitHub-Manager.desktop" || fail 'Não foi possível copiar o atalho da Área de Trabalho.'
fi
if [[ -e "$APP_ENTRY" ]]; then
  [[ -f "$APP_ENTRY" ]] || fail 'O atalho do menu não é arquivo regular.'
  had_app_entry=1
  cp -a -- "$APP_ENTRY" "$BACKUP/original/Applications-GitHub-Manager.desktop" || fail 'Não foi possível copiar o atalho do menu de aplicações.'
fi
# Snapshot de pacotes é informativo; rollback não desinstala dependências do sistema.
cat > "$BACKUP/rollback.sh" <<ROLLBACK_EOF
#!/usr/bin/env bash
set -Eeuo pipefail
BASE_PATH=$(printf '%q' "$BASE")
DESKTOP_PATH=$(printf '%q' "$DESKTOP_ENTRY")
APP_ENTRY_PATH=$(printf '%q' "$APP_ENTRY")
BACKUP_PATH=$(printf '%q' "$BACKUP")
HAD_BASE=$had_base
HAD_DESKTOP=$had_desktop
HAD_APP_ENTRY=$had_app_entry
# O rollback só pode atuar nos destinos exatos definidos pelo instalador.
[[ -n "\$HOME" && "\$HOME" == /* && "\$HOME" != "/" ]] || { echo "HOME inválido; rollback bloqueado." >&2; exit 1; }
[[ ! -L "\$HOME/.local" && ! -L "\$HOME/.local/share" && ! -L "\$HOME/.local/state" && ! -L "\$HOME/.local/share/applications" ]] || { echo "Diretório pai simbólico; rollback bloqueado." >&2; exit 1; }
[[ "\$BASE_PATH" == "\$HOME/.local/share/github-manager" && "\$BASE_PATH" != "/" && ! -L "\$BASE_PATH" ]] || { echo "Caminho BASE inesperado/link simbólico; rollback bloqueado." >&2; exit 1; }
[[ "\$APP_ENTRY_PATH" == "\$HOME/.local/share/applications/GitHub-Manager.desktop" && ! -L "\$APP_ENTRY_PATH" ]] || { echo "Caminho do menu inesperado/link simbólico; rollback bloqueado." >&2; exit 1; }
[[ -n "\$DESKTOP_PATH" && "\$DESKTOP_PATH" != "/" && "\$DESKTOP_PATH" == */GitHub-Manager.desktop && ! -L "\$DESKTOP_PATH" && ! -L "$(dirname -- "\$DESKTOP_PATH")" ]] || { echo "Caminho da Área de Trabalho inesperado/link simbólico; rollback bloqueado." >&2; exit 1; }
[[ "\$BACKUP_PATH" == "\$HOME/.local/state/github-manager-backups/"* && -d "\$BACKUP_PATH/original" && ! -L "\$BACKUP_PATH" && ! -L "\$BACKUP_PATH/original" && ! -L "\$HOME/.local/state/github-manager-backups" ]] || { echo "Backup inválido; rollback bloqueado." >&2; exit 1; }
if (( HAD_BASE )); then [[ -d "\$BACKUP_PATH/original/github-manager" && ! -L "\$BACKUP_PATH/original/github-manager" ]] || { echo "Cópia original da instalação ausente/inválida; rollback bloqueado." >&2; exit 1; }; fi
if (( HAD_DESKTOP )); then [[ -f "\$BACKUP_PATH/original/Desktop-GitHub-Manager.desktop" && ! -L "\$BACKUP_PATH/original/Desktop-GitHub-Manager.desktop" ]] || { echo "Cópia original do atalho ausente/inválida; rollback bloqueado." >&2; exit 1; }; fi
if (( HAD_APP_ENTRY )); then [[ -f "\$BACKUP_PATH/original/Applications-GitHub-Manager.desktop" && ! -L "\$BACKUP_PATH/original/Applications-GitHub-Manager.desktop" ]] || { echo "Cópia original do menu ausente/inválida; rollback bloqueado." >&2; exit 1; }; fi
if (( HAD_BASE )); then
  rm -rf -- "\$BASE_PATH"
  cp -a -- "\$BACKUP_PATH/original/github-manager" "\$BASE_PATH"
else
  rm -rf -- "\$BASE_PATH"
fi
if (( HAD_DESKTOP )); then
  rm -f -- "\$DESKTOP_PATH"
  cp -a -- "\$BACKUP_PATH/original/Desktop-GitHub-Manager.desktop" "\$DESKTOP_PATH"
else
  rm -f -- "\$DESKTOP_PATH"
fi
if (( HAD_APP_ENTRY )); then
  rm -f -- "\$APP_ENTRY_PATH"
  cp -a -- "\$BACKUP_PATH/original/Applications-GitHub-Manager.desktop" "\$APP_ENTRY_PATH"
else
  rm -f -- "\$APP_ENTRY_PATH"
fi
printf 'Rollback concluído. Backup usado: %s\n' "\$BACKUP_PATH"
ROLLBACK_EOF
chmod 700 "$BACKUP/rollback.sh"
trap 'status=$?; if (( status != 0 )); then printf "\nFalha após o backup; tentando restaurar o estado anterior...\n" >&2; "$BACKUP/rollback.sh" || true; fi' EXIT
say 'Backup concluído. A instalação anterior pode ser restaurada por rollback.sh.'
printf 'Backup: %s\nRollback: %s/rollback.sh\n' "$BACKUP" "$BACKUP"

say 'ETAPA 3/4 — Criando o aplicativo com os códigos Bash e Python incorporados.'
[[ ! -L "$BASE" && ! -L "$DESKTOP_DIR" && ! -L "$HOME/.local/share/applications" && ! -L "$DESKTOP_ENTRY" && ! -L "$APP_ENTRY" ]] || fail 'Link simbólico detectado no destino de instalação/atalho.'
mkdir -p "$BASE" "$DESKTOP_DIR" "$HOME/.local/share/applications" || fail 'Não foi possível preparar as pastas de instalação.'
APP="$BASE/github-manager.sh"; GUI="$BASE/github-manager-gui.py"
[[ ! -L "$APP" && ! -L "$GUI" ]] || fail 'O núcleo ou a interface existente é um link simbólico. Instalação bloqueada.'
APP_TMP="$(mktemp "$BASE/.github-manager.sh.XXXXXXXX")" || fail 'Não foi possível preparar o núcleo Bash temporário.'
cat > "$APP_TMP" <<'GITHUB_MANAGER_APP_EOF_9A71C2'
#!/usr/bin/env bash
# GitHub Manager Desktop - núcleo Bash (funções originais do usuário, executadas pela interface gráfica).
umask 077
APP_TITLE="GitHub Manager — GIT LOCAL"
command -v curl >/dev/null 2>&1 || { printf 'Dependência ausente: curl. Execute novamente o instalador.\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'Dependência ausente: jq. Execute novamente o instalador.\n' >&2; exit 1; }
if [[ "${1:-}" != "--task" ]]; then
  command -v zenity >/dev/null 2>&1 || { printf 'Dependência ausente: zenity. Execute novamente o instalador.\n' >&2; exit 1; }
fi
GUI_LAST_PROMPT=""
GUI_CANCELLED=0
# Log local de ações destrutivas (apenas registro; nunca envia dados para fora).
AUDIT_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/github-manager/audit.log"
audit_log() {
  local action="$1" detail="${2:-}"
  mkdir -p "$(dirname -- "$AUDIT_LOG")" 2>/dev/null || return 0
  printf '%s | user=%s | %s | %s\n' "$(date -Is 2>/dev/null || date)" "${GITHUB_USER:-?}" "$action" "$detail" >> "$AUDIT_LOG" 2>/dev/null || true
}
# O printf mantém a saída original e registra prompts sem quebra de linha para a próxima caixa de entrada.
printf() {
  builtin printf "$@"
  local rendered=""
  if [[ "${1-}" != "-v" ]]; then
    builtin printf -v rendered "$@" 2>/dev/null || rendered=""
    case "$rendered" in
      *$'\n') ;;
      *)
        if [[ -n "${rendered//[[:space:]]/}" ]]; then GUI_LAST_PROMPT="$rendered"; fi
        ;;
    esac
  fi
}
gui_read() {
  local varname="${1:-value}" value="" prompt="${GUI_LAST_PROMPT:-Informe o valor solicitado}" result
  GUI_LAST_PROMPT=""
  if [[ "${GUI_EMBEDDED:-0}" == 1 ]]; then
    # Protocolo simples com a interface Python: a pergunta aparece na tela principal.
    prompt="${prompt//$'\n'/ }"
    builtin printf '\n__GUI_PROMPT__%s\n' "$prompt"
    if ! IFS= read -r value; then value=""; fi
    builtin printf -v "$varname" '%s' "$value"
    return 0
  fi
  case "$prompt" in
    *"arquivo local"*|*"Selecione o arquivo local"*)
      result=$(zenity --file-selection --title="$APP_TITLE" --text="$prompt" 2>/dev/null) || { GUI_CANCELLED=1; value=""; }
      ;;
    *"diretório local"*|*"Diretório de destino"*|*"pasta local"*)
      result=$(zenity --file-selection --directory --title="$APP_TITLE" --text="$prompt" 2>/dev/null) || { GUI_CANCELLED=1; value=""; }
      ;;
    *)
      result=$(zenity --entry --title="$APP_TITLE" --text="$prompt" --width=560 2>/dev/null) || { GUI_CANCELLED=1; value=""; }
      ;;
  esac
  if [[ ${GUI_CANCELLED:-0} -eq 1 ]]; then value=""; GUI_CANCELLED=0; else value="$result"; fi
  builtin printf -v "$varname" '%s' "$value"
  return 0
}
PROGRAM_NAME="GitHub Manager"
API_URL="https://api.github.com"
API_VERSION="2022-11-28"
GITHUB_USER="${GITHUB_USER:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
SSH_KEY="${SSH_KEY:-}"
TMP_PARENT="${TMPDIR:-/tmp}"
[[ "$TMP_PARENT" == /* && -d "$TMP_PARENT" ]] || { printf 'Diretório temporário inválido.\n' >&2; exit 1; }
TMP_PARENT="$(cd -- "$TMP_PARENT" 2>/dev/null && pwd -P)" || exit 1
TMP_DIR="$(mktemp -d "$TMP_PARENT/github-manager.XXXXXXXX")" || { printf 'Não foi possível criar diretório temporário seguro.\n' >&2; exit 1; }
chmod 700 "$TMP_DIR" || exit 1
cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && ! -L "$TMP_DIR" && "$TMP_DIR" == "$TMP_PARENT"/github-manager.* ]]; then
    rm -rf -- "$TMP_DIR"
  else
    printf 'AVISO: limpeza temporária bloqueada por validação de caminho.\n' >&2
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
valid_name() {
  case "$1" in
    ""|*[!a-zA-Z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}
urlencode() {
  jq -nr --arg value "$1" '$value|@uri'
}
api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  local output="${4:-$TMP_DIR/response.json}"
  local status curl_rc output_dir

  case "$output" in
    "$TMP_DIR"/*) ;;
    *) printf 'Erro: saída da API fora da área temporária protegida.\n' >&2; return 1 ;;
  esac
  output_dir="$(dirname "$output")"
  if ! mkdir -p "$TMP_DIR"; then
    printf 'Erro: não foi possível preparar o diretório temporário.\n' >&2
    return 1
  fi
  : > "$output" || {
    printf 'Erro: não foi possível criar o arquivo de resposta: %s\n' "$output" >&2
    return 1
  }

  if [ -n "$data" ]; then
    status=$(curl -sS -o "$output" -w '%{http_code}' \
      -X "$method" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      -H "Content-Type: application/json" \
      --data-binary "$data" \
      "$API_URL$endpoint")
    curl_rc=$?
  else
    status=$(curl -sS -o "$output" -w '%{http_code}' \
      -X "$method" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "$API_URL$endpoint")
    curl_rc=$?
  fi

  if [ "$curl_rc" -ne 0 ]; then
    printf 'Falha de comunicação com o GitHub (curl: %s).\n' "$curl_rc" >&2
    [ -s "$output" ] && jq -r '.message // empty' "$output" 2>/dev/null
    return 1
  fi

  case "$status" in
    200|201|202|204) return 0 ;;
    401)
      printf '\nErro de autenticação (HTTP 401). Token inválido, expirado ou sem permissão.\n'
      printf 'Gere um novo PAT em https://github.com/settings/tokens e tente novamente.\n'
      [ -s "$output" ] && jq -r '.message // empty' "$output" 2>/dev/null
      return 1
      ;;
    403)
      printf '\nAcesso negado (HTTP 403).\n'
      if jq -e '.message | test("rate limit|API rate limit"; "i")' "$output" >/dev/null 2>&1; then
        printf 'Limite de requisições da API do GitHub atingido. Aguarde alguns minutos e tente de novo.\n'
        remaining=$(jq -r '.message // empty' "$output" 2>/dev/null)
        [ -n "$remaining" ] && printf 'Detalhe: %s\n' "$remaining"
      else
        printf 'O token não tem permissão suficiente para esta operação ou o recurso está protegido.\n'
        [ -s "$output" ] && jq -r '.message // empty' "$output" 2>/dev/null
      fi
      return 1
      ;;
    404)
      printf '\nRecurso não encontrado (HTTP 404). Verifique o nome do repositório, branch ou caminho.\n'
      [ -s "$output" ] && jq -r '.message // empty' "$output" 2>/dev/null
      return 1
      ;;
    422)
      printf '\nDados inválidos (HTTP 422). O GitHub rejeitou a operação.\n'
      [ -s "$output" ] && jq -r '.message // empty, (.errors[]?.message // empty)' "$output" 2>/dev/null
      return 1
      ;;
    429)
      printf '\nMuitas requisições (HTTP 429). Limite de taxa excedido. Aguarde e tente novamente.\n'
      [ -s "$output" ] && jq -r '.message // empty' "$output" 2>/dev/null
      return 1
      ;;
    *)
      printf '\nErro na API do GitHub (HTTP %s).\n' "$status"
      if [ -s "$output" ]; then
        jq -r '.message // .' "$output" 2>/dev/null || cat "$output"
      fi
      return 1
      ;;
  esac
}
ensure_login() {
  if [ -z "$GITHUB_USER" ] || [ -z "$GITHUB_TOKEN" ]; then
    printf '\nFaça login no GitHub primeiro.\n'
    return 1
  fi
  return 0
}
logout_github() {
  GITHUB_USER=""
  GITHUB_TOKEN=""
  SSH_KEY=""
  printf '\nSessão encerrada.\n'
}
list_repositories() {
  local page count repo default_branch private path depth indent
  ensure_login || return 1
  page=1
  while :; do
    if ! api GET \
      "/user/repos?affiliation=owner&per_page=100&page=$page&sort=full_name" \
      "" "$TMP_DIR/repos.json"; then
      return 1
    fi
    count=$(jq 'length' "$TMP_DIR/repos.json" 2>/dev/null)
    [ -n "$count" ] || return 1
    [ "$count" -gt 0 ] || break
    while IFS="$(printf '\t')" read -r repo default_branch private; do
      [ -n "$repo" ] || continue
      printf '\n============================================================\n'
      printf 'REPOSITÓRIO      : %s\n' "$repo"
      printf 'BRANCH PRINCIPAL : %s\n' "$default_branch"
      printf 'PRIVADO          : %s\n' "$private"
      printf '%s\n' 'DIRETÓRIOS E SUBPASTAS:'
      if api GET \
        "/repos/$GITHUB_USER/$(urlencode "$repo")/git/trees/$(urlencode "$default_branch")?recursive=1" \
        "" "$TMP_DIR/tree.json"; then
        if [ "$(jq -r '.truncated // false' "$TMP_DIR/tree.json" 2>/dev/null)" = "true" ]; then
          printf '  AVISO: a API informou que a árvore foi truncada.\n'
        fi
        jq -r '.tree[]? | select(.type == "tree") | .path' \
          "$TMP_DIR/tree.json" |
        while IFS= read -r path; do
          [ -n "$path" ] || continue
          depth=$(printf '%s\n' "$path" | awk -F '/' '{print NF-1}')
          indent="  "
          while [ "$depth" -gt 0 ]; do
            indent="${indent}  "
            depth=$((depth - 1))
          done
          printf '%s📁 %s\n' "$indent" "$path"
        done
        if ! jq -e '.tree[]? | select(.type == "tree")' \
          "$TMP_DIR/tree.json" >/dev/null 2>&1; then
          printf '  (Nenhuma pasta encontrada.)\n'
        fi
      else
        printf '  Não foi possível consultar os diretórios desta branch.\n'
      fi
    done < <(
      jq -r '.[] | [.name,.default_branch,(.private|tostring)] | @tsv' \
        "$TMP_DIR/repos.json"
    )
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
  done
}
create_repository_main() {
  local name description visibility payload
  ensure_login || return 1
  printf '\nNome do novo repositório: '
  gui_read name
  valid_name "$name" || {
    printf 'Nome inválido.\n'
    return 1
  }
  printf 'Descrição (opcional): '
  gui_read description
  printf 'Repositório privado? (s/n): '
  gui_read visibility
  case "$visibility" in
    s|S|sim|SIM) visibility=true ;;
    *) visibility=false ;;
  esac
  payload=$(jq -n \
    --arg name "$name" \
    --arg description "$description" \
    --argjson private "$visibility" \
    '{name:$name,description:$description,private:$private,auto_init:true}')
  if api POST "/user/repos" "$payload"; then
    printf '\nRepositório criado: %s/%s\n' "$GITHUB_USER" "$name"
  fi
}
select_repository() {
  local name
  ensure_login || return 1
  printf '\nNome do repositório: '
  gui_read name
  valid_name "$name" || {
    printf 'Nome inválido.\n'
    return 1
  }
  if ! api GET "/repos/$GITHUB_USER/$(urlencode "$name")" \
    "" "$TMP_DIR/repo.json"; then
    return 1
  fi
  if [ ! -s "$TMP_DIR/repo.json" ] || ! jq -e 'type == "object" and (.default_branch | type == "string" and length > 0)' "$TMP_DIR/repo.json" >/dev/null 2>&1; then
    printf 'Erro: a resposta do GitHub está vazia ou inválida; o repositório não foi selecionado.\n'
    return 1
  fi
  SELECTED_REPO="$name"
  DEFAULT_BRANCH=$(jq -r '.default_branch' "$TMP_DIR/repo.json") || {
    SELECTED_REPO=""
    DEFAULT_BRANCH=""
    printf 'Erro: não foi possível identificar a branch principal.\n'
    return 1
  }
  return 0
}
upload_file() {
  local file remote_path encoded_repo encoded_path sha http_code answer local_dir
  ensure_login || return 1
  command -v base64 >/dev/null 2>&1 || { printf 'Erro: base64 não está disponível.\n'; return 1; }
  local_dir="$(get_local_base_dir)" || return 1
  printf '\n=== ENVIAR ARQUIVO LOCAL AO GITHUB ===\n'
  printf 'Diretório local configurado: %s\n' "$local_dir"
  select_repository || return 1
  printf 'Nome do arquivo local: '
  gui_read file
  case "$file" in ""|"."|".."|*/*|*\\*) printf 'Erro: informe somente o nome do arquivo, sem caminhos.\n'; return 1 ;; esac
  [[ -f "$local_dir/$file" && ! -L "$local_dir/$file" ]] || { printf 'Erro: arquivo não encontrado: %s/%s\n' "$local_dir" "$file"; return 1; }
  [ -r "$local_dir/$file" ] || { printf 'Erro: o arquivo não possui permissão de leitura.\n'; return 1; }
  # Contents API tem limite prático (~100 MB). Avisa o usuário antes de tentar.
  local fsize
  fsize=$(wc -c < "$local_dir/$file" 2>/dev/null || echo 0)
  if [ "$fsize" -gt 52428800 ]; then
    printf 'AVISO: arquivo com %s bytes. A API Contents do GitHub não é adequada para arquivos grandes (>50 MB).\n' "$fsize"
    printf 'Para arquivos grandes prefira git commit + push ou Git LFS.\n'
  fi
  if [ "$fsize" -gt 104857600 ]; then
    printf 'Erro: arquivo acima de 100 MB. Operação cancelada para evitar falha da API.\n'
    return 1
  fi
  remote_path="$file"
  encoded_repo=$(urlencode "$SELECTED_REPO") || return 1
  encoded_path=$(urlencode_path "$remote_path") || return 1
  if ! base64 < "$local_dir/$file" | tr -d '\r\n' > "$TMP_DIR/upload-content.b64"; then
    printf 'Erro: não foi possível codificar o arquivo.\n'; return 1
  fi
  http_code=$(curl -sS -o "$TMP_DIR/content.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$encoded_repo/contents/$encoded_path?ref=$(urlencode "$DEFAULT_BRANCH")") || {
    printf 'Falha de comunicação ao consultar o arquivo remoto.\n'; return 1;
  }
  sha=""
  case "$http_code" in
    200) sha=$(jq -r '.sha // empty' "$TMP_DIR/content.json"); [ -n "$sha" ] || { printf 'Não foi possível obter o SHA remoto.\n'; return 1; } ;;
    404) ;;
    *) printf 'Erro ao consultar arquivo remoto (HTTP %s).\n' "$http_code"; jq -r '.message // empty' "$TMP_DIR/content.json" 2>/dev/null; return 1 ;;
  esac
  if [ -n "$sha" ]; then
    printf 'O arquivo já existe na MAIN. Atualizar? (s=ATUALIZA / n=MANTÉM): '
    gui_read answer
    case "$answer" in s|S|sim|SIM) ;; *) printf 'Arquivo remoto mantido. Envio cancelado.\n'; return 0 ;; esac
  fi
  if ! jq -n \
    --arg message "Envio de $remote_path via GitHub Manager" \
    --rawfile content "$TMP_DIR/upload-content.b64" \
    --arg branch "$DEFAULT_BRANCH" --arg sha "$sha" \
    '{message:$message,content:($content|gsub("[\\r\\n]";"")),branch:$branch} + (if $sha != "" then {sha:$sha} else {} end)' \
    > "$TMP_DIR/upload-payload.json"; then
    printf 'Erro ao preparar o envio.\n'; return 1
  fi
  http_code=$(curl -sS -o "$TMP_DIR/upload.json" -w '%{http_code}' -X PUT \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    -H 'Content-Type: application/json' \
    --data-binary "@$TMP_DIR/upload-payload.json" \
    "$API_URL/repos/$GITHUB_USER/$encoded_repo/contents/$encoded_path") || {
    printf 'Falha de comunicação durante o envio.\n'; return 1;
  }
  case "$http_code" in
    200|201)
      if jq -e '.content.sha and .commit.sha' "$TMP_DIR/upload.json" >/dev/null 2>&1; then
        printf 'Arquivo enviado/atualizado com sucesso: %s\n' "$remote_path"
      else
        printf 'Erro: a API não confirmou o envio.\n'; jq -r '.message // empty' "$TMP_DIR/upload.json" 2>/dev/null; return 1
      fi ;;
    *) printf 'Falha no envio (HTTP %s).\n' "$http_code"; jq -r '.message // empty' "$TMP_DIR/upload.json" 2>/dev/null; return 1 ;;
  esac
}
download_file() {
  local branch path output encoded_path filename repo_encoded local_dir
  select_repository || return 1
  local_dir="$(get_local_base_dir)" || return 1
  printf 'Branch: '
  gui_read branch
  [ -n "$branch" ] || branch="$DEFAULT_BRANCH"
  printf 'Caminho do arquivo remoto: '
  gui_read path
  [ -n "$path" ] || {
    printf 'Caminho inválido.\n'
    return 1
  }
  filename="${path##*/}"
  [ -n "$filename" ] || {
    printf 'O caminho informado não contém um nome de arquivo válido.\n'
    return 1
  }
  case "$filename" in ""|"."|".."|*/*|*\\*) printf 'Nome de arquivo remoto inválido.\\n'; return 1 ;; esac
  [[ -d "$local_dir" && ! -L "$local_dir" ]] || { printf 'Diretório local inválido ou link simbólico.\n'; return 1; }
  output="$local_dir/$filename"
  if [[ -e "$output" || -L "$output" ]]; then
    printf 'O destino local já existe. Para evitar sobrescrita, download cancelado: %s\n' "$output"
    return 1
  fi
  encoded_path=$(urlencode_path "$path") || return 1
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  if ! api GET \
    "/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path?ref=$(urlencode "$branch")" \
    "" "$TMP_DIR/content.json"; then
    return 1
  fi
  if [ "$(jq -r '.type // empty' "$TMP_DIR/content.json")" != "file" ]; then
    printf 'O caminho informado não corresponde a um arquivo.\n'
    return 1
  fi
  local temp_output
  temp_output="$(mktemp "$local_dir/.github-manager-download.XXXXXXXX")" || { printf 'Não foi possível criar arquivo temporário no destino.\n'; return 1; }
  if ! jq -r '.content // empty' "$TMP_DIR/content.json" | tr -d '\n' | base64 -d > "$temp_output"; then
    rm -f -- "$temp_output"
    printf 'Falha ao gravar o arquivo temporário; destino final preservado.\n'
    return 1
  fi
  chmod 600 "$temp_output" || { rm -f -- "$temp_output"; return 1; }
  # ln é atômico e falha se o nome final já existir, inclusive como link simbólico.
  if ! ln -- "$temp_output" "$output"; then
    rm -f -- "$temp_output"
    printf 'O destino passou a existir ou não pode ser criado; nenhum arquivo foi sobrescrito.\n'
    return 1
  fi
  rm -f -- "$temp_output"
  printf '\nArquivo copiado com segurança para: %s\n' "$output"
}
delete_remote_file() {
  local branch path message sha payload answer encoded_path repo_encoded
  select_repository || return 1
  printf 'Branch: '
  gui_read branch
  [ -n "$branch" ] || branch="$DEFAULT_BRANCH"
  printf 'Caminho do arquivo remoto: '
  gui_read path
  [ -n "$path" ] || {
    printf 'Caminho inválido.\n'
    return 1
  }
  encoded_path=$(urlencode_path "$path") || return 1
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  if ! api GET \
    "/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path?ref=$(urlencode "$branch")" \
    "" "$TMP_DIR/content.json"; then
    return 1
  fi
  sha=$(jq -r '.sha // empty' "$TMP_DIR/content.json")
  [ -n "$sha" ] || {
    printf 'Não foi possível obter o SHA do arquivo.\n'
    return 1
  }
  printf 'Mensagem do commit de exclusão: '
  gui_read message
  [ -n "$message" ] || message="Exclusão via GitHub Manager"
  printf 'Confirma a exclusão de %s? (s/n): ' "$path"
  gui_read answer
  case "$answer" in
    s|S|sim|SIM) ;;
    *) printf 'Operação cancelada.\n'; return 0 ;;
  esac
  payload=$(jq -n \
    --arg message "$message" \
    --arg sha "$sha" \
    --arg branch "$branch" \
    '{message:$message,sha:$sha,branch:$branch}')
  if api DELETE \
    "/repos/$GITHUB_USER/$(urlencode "$SELECTED_REPO")/contents/$encoded_path" \
    "$payload"; then
    printf 'Arquivo excluído.\n'
  fi
}
urlencode_path() {
  local remaining component encoded separator
  remaining="$1"
  encoded=""
  separator=""
  while :; do
    case "$remaining" in
      */*) component="${remaining%%/*}"; remaining="${remaining#*/}" ;;
      *) component="$remaining"; remaining="" ;;
    esac
    encoded="${encoded}${separator}$(urlencode "$component")" || return 1
    separator="/"
    [ -n "$remaining" ] || break
  done
  printf '%s' "$encoded"
}
validate_remote_folder() {
  local folder remaining component
  folder="$1"
  [ -n "$folder" ] || return 1
  case "$folder" in /*|*/|*//*|*\\*) return 1 ;; esac
  remaining="$folder"
  while :; do
    case "$remaining" in
      */*) component="${remaining%%/*}"; remaining="${remaining#*/}" ;;
      *) component="$remaining"; remaining="" ;;
    esac
    case "$component" in ""|"."|"..") return 1 ;; esac
    [ -n "$remaining" ] || break
  done
  return 0
}
create_folder_main() {
  local folder repo_encoded path_encoded content payload status existing_status
  ensure_login || return 1
  select_repository || return 1
  printf 'Caminho da pasta a criar na MAIN PRINCIPAL: '
  gui_read folder
  folder=$(printf '%s' "$folder" | sed 's#^/*##;s#/*$##')
  validate_remote_folder "$folder" || {
    printf 'Caminho de pasta inválido. Exemplo: docs/guias\n'
    return 1
  }
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  path_encoded=$(urlencode_path "$folder/.gitkeep") || return 1
  existing_status=$(curl -sS -o "$TMP_DIR/folder-main-existing.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$path_encoded?ref=$(urlencode "$DEFAULT_BRANCH")") || {
    printf 'Falha de comunicação ao verificar a pasta.\n'
    return 1
  }
  case "$existing_status" in
    200)
      printf 'A pasta %s já existe na MAIN PRINCIPAL. Nenhuma alteração realizada.\n' "$folder"
      return 0
      ;;
    404) ;;
    *)
      printf 'Falha ao verificar a pasta (HTTP %s).\n' "$existing_status"
      jq -r '.message // empty' "$TMP_DIR/folder-main-existing.json" 2>/dev/null
      return 1
      ;;
  esac
  content=$(printf '%s' 'Pasta criada pelo GitHub Manager.' | base64 | tr -d '\r\n') || return 1
  payload=$(jq -n \
    --arg message "Criar pasta $folder na MAIN PRINCIPAL" \
    --arg content "$content" \
    --arg branch "$DEFAULT_BRANCH" \
    '{message:$message,content:$content,branch:$branch}') || return 1
  status=$(curl -sS -o "$TMP_DIR/create-folder-main.json" -w '%{http_code}' \
    -X PUT \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    -H 'Content-Type: application/json' \
    --data-binary "$payload" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$path_encoded") || {
    printf 'Falha de comunicação ao criar a pasta.\n'
    return 1
  }
  case "$status" in
    200|201)
      printf 'Pasta criada na MAIN PRINCIPAL: %s (branch %s)\n' "$folder" "$DEFAULT_BRANCH"
      ;;
    *)
      printf 'Falha ao criar pasta (HTTP %s).\n' "$status"
      jq -r '.message // empty' "$TMP_DIR/create-folder-main.json" 2>/dev/null
      return 1
      ;;
  esac
}
delete_folder_main() {
  local folder repo_encoded tree_status path encoded_path content_sha payload status confirm
  ensure_login || return 1
  select_repository || return 1
  printf 'Caminho da pasta a deletar na MAIN PRINCIPAL: '
  gui_read folder
  folder=$(printf '%s' "$folder" | sed 's#^/*##;s#/*$##')
  validate_remote_folder "$folder" || {
    printf 'Caminho de pasta inválido. Exemplo: docs/guias\n'
    return 1
  }
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  tree_status=$(curl -sS -o "$TMP_DIR/delete-folder-tree.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/git/trees/$(urlencode "$DEFAULT_BRANCH")?recursive=1") || {
    printf 'Falha ao consultar a árvore do repositório.\n'
    return 1
  }
  [ "$tree_status" = 200 ] || {
    printf 'Falha ao consultar a árvore (HTTP %s).\n' "$tree_status"
    jq -r '.message // empty' "$TMP_DIR/delete-folder-tree.json" 2>/dev/null
    return 1
  }
  jq -r --arg prefix "$folder/" '.tree[]? | select(.type == "blob" and (.path | startswith($prefix))) | .path' \
    "$TMP_DIR/delete-folder-tree.json" > "$TMP_DIR/delete-folder-files.txt"
  if [ ! -s "$TMP_DIR/delete-folder-files.txt" ]; then
    printf 'Nenhum arquivo encontrado na pasta "%s" na MAIN PRINCIPAL.\n' "$folder"
    return 1
  fi
  printf '\nArquivos que serão excluídos da pasta "%s":\n' "$folder"
  cat "$TMP_DIR/delete-folder-files.txt"
  printf '\nDigite DELETAR para confirmar a exclusão de todos esses arquivos: '
  gui_read confirm
  [ "$confirm" = DELETAR ] || {
    printf 'Operação cancelada.\n'
    return 0
  }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    encoded_path=$(urlencode_path "$path") || return 1
    status=$(curl -sS -o "$TMP_DIR/delete-folder-content.json" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path?ref=$(urlencode "$DEFAULT_BRANCH")") || {
      printf 'Falha de comunicação ao consultar: %s\n' "$path"
      return 1
    }
    [ "$status" = 200 ] || {
      printf 'Falha ao consultar "%s" (HTTP %s). Interrompendo.\n' "$path" "$status"
      jq -r '.message // empty' "$TMP_DIR/delete-folder-content.json" 2>/dev/null
      return 1
    }
    content_sha=$(jq -r '.sha // empty' "$TMP_DIR/delete-folder-content.json")
    [ -n "$content_sha" ] || {
      printf 'Não foi possível obter o SHA de: %s\n' "$path"
      return 1
    }
    payload=$(jq -n --arg message "Excluir $path da MAIN via GitHub Manager" --arg sha "$content_sha" --arg branch "$DEFAULT_BRANCH" '{message:$message,sha:$sha,branch:$branch}') || return 1
    status=$(curl -sS -o "$TMP_DIR/delete-folder-result.json" -w '%{http_code}' \
      -X DELETE \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      -H 'Content-Type: application/json' \
      --data-binary "$payload" \
      "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path") || {
      printf 'Falha de comunicação ao excluir: %s\n' "$path"
      return 1
    }
    case "$status" in
      200) printf 'Excluído: %s\n' "$path" ;;
      *)
        printf 'Falha ao excluir "%s" (HTTP %s). Interrompendo.\n' "$path" "$status"
        jq -r '.message // empty' "$TMP_DIR/delete-folder-result.json" 2>/dev/null
        return 1
        ;;
    esac
  done < "$TMP_DIR/delete-folder-files.txt"
  printf '\nConteúdo da pasta "%s" excluído da MAIN PRINCIPAL.\n' "$folder"
  printf 'Observação: o GitHub não armazena diretórios vazios; a pasta deixa de aparecer\n'
  printf 'quando todos os arquivos são removidos.\n'
  audit_log "DELETE_FOLDER_MAIN" "$SELECTED_REPO/$folder"
}
create_secondary_branch() {
  local branch_name repo_encoded payload base_commit_sha base_tree_sha
  local ref_status path encoded_path file_sha delete_payload delete_status
  ensure_login || return 1
  select_repository || return 1
  printf 'Nome da BRANCH secundária vazia: '
  gui_read branch_name
  branch_name=$(printf '%s' "$branch_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$branch_name" ] || { printf 'Nome inválido.\n'; return 1; }
  if command -v git >/dev/null 2>&1 && ! git check-ref-format "refs/heads/$branch_name" >/dev/null 2>&1; then
    printf 'Nome de branch inválido segundo as regras do Git.\n'
    return 1
  fi
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1

  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/git/ref/heads/$(urlencode "$DEFAULT_BRANCH")" "" "$TMP_DIR/empty-branch-base-ref.json"; then
    printf 'Não foi possível consultar a BRANCH PRINCIPAL.\n'
    return 1
  fi
  base_commit_sha=$(jq -r '.object.sha // empty' "$TMP_DIR/empty-branch-base-ref.json")
  [ -n "$base_commit_sha" ] || { printf 'Não foi possível obter o commit da BRANCH PRINCIPAL.\n'; return 1; }

  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/git/commits/$base_commit_sha" "" "$TMP_DIR/empty-branch-base-commit.json"; then
    printf 'Não foi possível consultar o commit da BRANCH PRINCIPAL.\n'
    return 1
  fi
  base_tree_sha=$(jq -r '.tree.sha // empty' "$TMP_DIR/empty-branch-base-commit.json")
  [ -n "$base_tree_sha" ] || { printf 'Não foi possível obter a árvore da BRANCH PRINCIPAL.\n'; return 1; }

  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/git/trees/$base_tree_sha?recursive=1" "" "$TMP_DIR/empty-branch-all-files.json"; then
    printf 'Não foi possível listar os arquivos da BRANCH PRINCIPAL.\n'
    return 1
  fi
  if ! jq -e '.tree | type == "array"' "$TMP_DIR/empty-branch-all-files.json" >/dev/null 2>&1; then
    printf 'A resposta da árvore principal é inválida.\n'
    return 1
  fi
  jq -r '.tree[]? | select(.type == "blob") | .path' "$TMP_DIR/empty-branch-all-files.json" > "$TMP_DIR/empty-branch-files.txt" || return 1

  payload=$(jq -n --arg ref "refs/heads/$branch_name" --arg sha "$base_commit_sha" '{ref:$ref,sha:$sha}') || return 1
  if ! api POST "/repos/$GITHUB_USER/$repo_encoded/git/refs" "$payload" "$TMP_DIR/new-branch.json"; then
    printf 'Não foi possível registrar a BRANCH. Verifique se ela já existe e se o token tem permissão para gravar.\n'
    return 1
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    encoded_path=$(urlencode_path "$path") || return 1
    delete_status=$(curl -sS -o "$TMP_DIR/empty-branch-content.json" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path?ref=$(urlencode "$branch_name")") || {
      printf 'Falha de comunicação ao consultar o arquivo: %s\n' "$path"
      printf 'A branch foi criada, mas pode não estar vazia.\n'
      return 1
    }
    if [ "$delete_status" != 200 ]; then
      printf 'Falha ao consultar "%s" na nova branch (HTTP %s).\n' "$path" "$delete_status"
      jq -r '.message // empty' "$TMP_DIR/empty-branch-content.json" 2>/dev/null
      printf 'A branch foi criada, mas pode não estar vazia.\n'
      return 1
    fi
    file_sha=$(jq -r '.sha // empty' "$TMP_DIR/empty-branch-content.json")
    [ -n "$file_sha" ] || { printf 'Não foi possível obter o SHA do arquivo: %s\n' "$path"; return 1; }
    delete_payload=$(jq -n \
      --arg message "Esvaziar branch $branch_name: remover $path" \
      --arg sha "$file_sha" \
      --arg branch "$branch_name" \
      '{message:$message,sha:$sha,branch:$branch}') || return 1
    delete_status=$(curl -sS -o "$TMP_DIR/empty-branch-delete.json" -w '%{http_code}' \
      -X DELETE \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      -H 'Content-Type: application/json' \
      --data-binary "$delete_payload" \
      "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path") || {
      printf 'Falha de comunicação ao remover: %s\n' "$path"
      printf 'A branch foi criada, mas pode não estar vazia.\n'
      return 1
    }
    case "$delete_status" in
      200) : ;;
      *)
        printf 'Falha ao remover "%s" da nova branch (HTTP %s).\n' "$path" "$delete_status"
        jq -r '.message // empty' "$TMP_DIR/empty-branch-delete.json" 2>/dev/null
        printf 'A branch foi criada, mas pode não estar vazia.\n'
        return 1
        ;;
    esac
  done < "$TMP_DIR/empty-branch-files.txt"

  printf 'BRANCH secundária criada: %s\n' "$branch_name"
  printf 'Os arquivos foram removidos da branch; a MAIN PRINCIPAL não foi alterada.\n'
  printf 'Observação: o histórico da branch permanece vinculado ao commit de origem.\n'
}

delete_secondary_branch() {
  local branch_name repo_encoded branch_encoded confirm status
  ensure_login || return 1
  select_repository || return 1
  printf '\nBRANCH PRINCIPAL protegida: %s\n' "$DEFAULT_BRANCH"
  printf 'Nome exato da BRANCH secundária a deletar: '
  gui_read branch_name
  [ -n "$branch_name" ] || {
    printf 'Nome de branch inválido.\n'
    return 1
  }
  if [ "$branch_name" = "$DEFAULT_BRANCH" ]; then
    printf 'Operação bloqueada: não é permitido deletar a BRANCH PRINCIPAL.\n'
    return 1
  fi
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  branch_encoded=$(urlencode "$branch_name") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/branches/$branch_encoded" "" "$TMP_DIR/branch-to-delete.json"; then
    printf 'A branch informada não foi localizada ou não pode ser consultada.\n'
    return 1
  fi
  printf '\nRepositório : %s\n' "$SELECTED_REPO"
  printf 'Branch      : %s\n' "$branch_name"
  printf 'Digite DELETAR para confirmar: '
  gui_read confirm
  [ "$confirm" = DELETAR ] || {
    printf 'Operação cancelada.\n'
    return 0
  }
  status=$(curl -sS -o "$TMP_DIR/delete-secondary-branch.json" -w '%{http_code}' \
    -X DELETE \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/git/refs/heads/$branch_encoded") || {
    printf 'Falha de comunicação ao deletar a branch.\n'
    return 1
  }
  case "$status" in
    204) printf 'BRANCH secundária "%s" deletada com sucesso.\n' "$branch_name"; audit_log "DELETE_BRANCH" "$SELECTED_REPO/$branch_name" ;;
    *)
      printf 'Falha ao deletar a branch (HTTP %s).\n' "$status"
      jq -r '.message // empty' "$TMP_DIR/delete-secondary-branch.json" 2>/dev/null
      return 1
      ;;
  esac
}
rename_secondary_branch() {
  local old_branch new_branch repo_encoded old_ref_encoded new_ref_encoded sha payload confirm status
  ensure_login || return 1
  select_repository || return 1
  printf '\nBRANCH PRINCIPAL protegida: %s\n' "$DEFAULT_BRANCH"
  printf 'Nome atual da BRANCH secundária: '
  gui_read old_branch
  [ -n "$old_branch" ] || {
    printf 'Nome de branch inválido.\n'
    return 1
  }
  if [ "$old_branch" = "$DEFAULT_BRANCH" ]; then
    printf 'Operação bloqueada: não é permitido renomear a BRANCH PRINCIPAL.\n'
    return 1
  fi
  printf 'Novo nome da BRANCH secundária: '
  gui_read new_branch
  [ -n "$new_branch" ] || {
    printf 'Novo nome de branch inválido.\n'
    return 1
  }
  [ "$old_branch" != "$new_branch" ] || {
    printf 'O nome novo é igual ao nome atual. Nenhuma alteração realizada.\n'
    return 1
  }
  if [ "$new_branch" = "$DEFAULT_BRANCH" ]; then
    printf 'O novo nome não pode ser o da BRANCH PRINCIPAL.\n'
    return 1
  fi
  if command -v git >/dev/null 2>&1 && ! git check-ref-format "refs/heads/$new_branch" >/dev/null 2>&1; then
    printf 'Novo nome de branch inválido segundo as regras do Git.\n'
    return 1
  fi
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  old_ref_encoded=$(urlencode_path "$old_branch") || return 1
  new_ref_encoded=$(urlencode_path "$new_branch") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/git/ref/heads/$old_ref_encoded" "" "$TMP_DIR/rename-branch-old-ref.json"; then
    printf 'A BRANCH atual não foi localizada.\n'
    return 1
  fi
  sha=$(jq -r '.object.sha // empty' "$TMP_DIR/rename-branch-old-ref.json")
  [ -n "$sha" ] || {
    printf 'Não foi possível obter o commit da BRANCH atual.\n'
    return 1
  }
  status=$(curl -sS -o "$TMP_DIR/rename-branch-new-check.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/git/ref/heads/$new_ref_encoded") || {
    printf 'Falha ao verificar o novo nome da BRANCH.\n'
    return 1
  }
  case "$status" in
    200)
      printf 'Já existe uma BRANCH chamada "%s".\n' "$new_branch"
      return 1
      ;;
    404) ;;
    *)
      printf 'Falha ao verificar o novo nome (HTTP %s).\n' "$status"
      jq -r '.message // empty' "$TMP_DIR/rename-branch-new-check.json" 2>/dev/null
      return 1
      ;;
  esac
  printf '\nRepositório : %s\n' "$SELECTED_REPO"
  printf 'BRANCH atual: %s\n' "$old_branch"
  printf 'Novo nome   : %s\n' "$new_branch"
  printf 'A operação criará a nova referência e depois excluirá a antiga.\n'
  printf 'Digite RENOMEAR para confirmar: '
  gui_read confirm
  [ "$confirm" = RENOMEAR ] || {
    printf 'Operação cancelada.\n'
    return 0
  }
  payload=$(jq -n --arg ref "refs/heads/$new_branch" --arg sha "$sha" '{ref:$ref,sha:$sha}') || return 1
  if ! api POST "/repos/$GITHUB_USER/$repo_encoded/git/refs" "$payload" "$TMP_DIR/rename-branch-create.json"; then
    printf 'Não foi possível criar a nova BRANCH; a antiga foi mantida.\n'
    return 1
  fi
  status=$(curl -sS -o "$TMP_DIR/rename-branch-delete.json" -w '%{http_code}' \
    -X DELETE \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/git/refs/heads/$old_ref_encoded") || {
    printf 'A nova BRANCH foi criada, mas houve falha de comunicação ao excluir a antiga.\n'
    printf 'Nova BRANCH: %s | BRANCH antiga ainda pode existir: %s\n' "$new_branch" "$old_branch"
    return 1
  }
  case "$status" in
    204) printf 'BRANCH renomeada: %s -> %s\n' "$old_branch" "$new_branch" ;;
    *)
      printf 'A nova BRANCH foi criada, mas a antiga não foi excluída (HTTP %s).\n' "$status"
      jq -r '.message // empty' "$TMP_DIR/rename-branch-delete.json" 2>/dev/null
      printf 'Verifique as duas BRANCHES no GitHub antes de repetir a operação.\n'
      return 1
      ;;
  esac
}
create_folder_secondary_branch() {
  local branch_name folder repo_encoded path_encoded content payload status existing_status
  ensure_login || return 1
  select_repository || return 1
  printf 'Nome da BRANCH secundária existente: '
  gui_read branch_name
  [ -n "$branch_name" ] || {
    printf 'Nome de branch inválido.\n'
    return 1
  }
  if [ "$branch_name" = "$DEFAULT_BRANCH" ]; then
    printf 'Informe uma branch secundária, não a MAIN PRINCIPAL.\n'
    return 1
  fi
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  if ! api GET \
    "/repos/$GITHUB_USER/$repo_encoded/branches/$(urlencode "$branch_name")" \
    "" "$TMP_DIR/secondary-branch.json"; then
    return 1
  fi
  printf 'Caminho da pasta a criar na BRANCH secundária: '
  gui_read folder
  folder=$(printf '%s' "$folder" | sed 's#^/*##;s#/*$##')
  validate_remote_folder "$folder" || {
    printf 'Caminho de pasta inválido. Exemplo: docs/guias\n'
    return 1
  }
  path_encoded=$(urlencode_path "$folder/.gitkeep") || return 1
  existing_status=$(curl -sS -o "$TMP_DIR/folder-branch-existing.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$path_encoded?ref=$(urlencode "$branch_name")") || {
    printf 'Falha de comunicação ao verificar a pasta.\n'
    return 1
  }
  case "$existing_status" in
    200)
      printf 'A pasta %s já existe na BRANCH %s. Nenhuma alteração realizada.\n' "$folder" "$branch_name"
      return 0
      ;;
    404) ;;
    *)
      printf 'Falha ao verificar a pasta (HTTP %s).\n' "$existing_status"
      jq -r '.message // empty' "$TMP_DIR/folder-branch-existing.json" 2>/dev/null
      return 1
      ;;
  esac
  content=$(printf '%s' 'Pasta criada pelo GitHub Manager.' | base64 | tr -d '\r\n') || return 1
  payload=$(jq -n \
    --arg message "Criar pasta $folder na branch $branch_name" \
    --arg content "$content" \
    --arg branch "$branch_name" \
    '{message:$message,content:$content,branch:$branch}') || return 1
  status=$(curl -sS -o "$TMP_DIR/create-folder-branch.json" -w '%{http_code}' \
    -X PUT \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    -H 'Content-Type: application/json' \
    --data-binary "$payload" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$path_encoded") || {
    printf 'Falha de comunicação ao criar a pasta.\n'
    return 1
  }
  case "$status" in
    200|201)
      printf 'Pasta criada na BRANCH secundária: %s (branch %s)\n' "$folder" "$branch_name"
      ;;
    *)
      printf 'Falha ao criar pasta (HTTP %s).\n' "$status"
      jq -r '.message // empty' "$TMP_DIR/create-folder-branch.json" 2>/dev/null
      return 1
      ;;
  esac
}
delete_folder_secondary_branch() {
  local branch_name folder repo_encoded tree_status path encoded_path content_sha payload status confirm
  ensure_login || return 1
  select_repository || return 1
  printf 'Nome da BRANCH secundária existente: '
  gui_read branch_name
  [ -n "$branch_name" ] || {
    printf 'Nome de branch inválido.\n'
    return 1
  }
  if [ "$branch_name" = "$DEFAULT_BRANCH" ]; then
    printf 'Operação bloqueada: informe uma BRANCH secundária, não a MAIN PRINCIPAL.\n'
    return 1
  fi
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/branches/$(urlencode "$branch_name")" "" "$TMP_DIR/secondary-branch-to-delete-folder.json"; then
    printf 'A BRANCH secundária informada não foi localizada ou não pode ser consultada.\n'
    return 1
  fi
  printf 'Caminho da pasta a deletar na BRANCH secundária: '
  gui_read folder
  folder=$(printf '%s' "$folder" | sed 's#^/*##;s#/*$##')
  validate_remote_folder "$folder" || {
    printf 'Caminho de pasta inválido. Exemplo: docs/guias\n'
    return 1
  }
  tree_status=$(curl -sS -o "$TMP_DIR/delete-folder-branch-tree.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/git/trees/$(urlencode "$branch_name")?recursive=1") || {
    printf 'Falha ao consultar a árvore da BRANCH secundária.\n'
    return 1
  }
  [ "$tree_status" = 200 ] || {
    printf 'Falha ao consultar a árvore da BRANCH (HTTP %s).\n' "$tree_status"
    jq -r '.message // empty' "$TMP_DIR/delete-folder-branch-tree.json" 2>/dev/null
    return 1
  }
  jq -r --arg prefix "$folder/" '.tree[]? | select(.type == "blob" and (.path | startswith($prefix))) | .path' \
    "$TMP_DIR/delete-folder-branch-tree.json" > "$TMP_DIR/delete-folder-branch-files.txt"
  if [ ! -s "$TMP_DIR/delete-folder-branch-files.txt" ]; then
    printf 'Nenhum arquivo encontrado na pasta "%s" na BRANCH "%s".\n' "$folder" "$branch_name"
    return 1
  fi
  printf '\nRepositório     : %s\n' "$SELECTED_REPO"
  printf 'BRANCH secundária: %s\n' "$branch_name"
  printf 'Arquivos que serão excluídos da pasta "%s":\n' "$folder"
  cat "$TMP_DIR/delete-folder-branch-files.txt"
  printf '\nDigite DELETAR para confirmar a exclusão de todos esses arquivos: '
  gui_read confirm
  [ "$confirm" = DELETAR ] || {
    printf 'Operação cancelada.\n'
    return 0
  }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    encoded_path=$(urlencode_path "$path") || return 1
    status=$(curl -sS -o "$TMP_DIR/delete-folder-branch-content.json" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path?ref=$(urlencode "$branch_name")") || {
      printf 'Falha de comunicação ao consultar: %s\n' "$path"
      return 1
    }
    [ "$status" = 200 ] || {
      printf 'Falha ao consultar "%s" (HTTP %s). Interrompendo.\n' "$path" "$status"
      jq -r '.message // empty' "$TMP_DIR/delete-folder-branch-content.json" 2>/dev/null
      return 1
    }
    content_sha=$(jq -r '.sha // empty' "$TMP_DIR/delete-folder-branch-content.json")
    [ -n "$content_sha" ] || {
      printf 'Não foi possível obter o SHA de: %s\n' "$path"
      return 1
    }
    payload=$(jq -n --arg message "Excluir $path da BRANCH $branch_name via GitHub Manager" --arg sha "$content_sha" --arg branch "$branch_name" '{message:$message,sha:$sha,branch:$branch}') || return 1
    status=$(curl -sS -o "$TMP_DIR/delete-folder-branch-result.json" -w '%{http_code}' \
      -X DELETE \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      -H 'Content-Type: application/json' \
      --data-binary "$payload" \
      "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path") || {
      printf 'Falha de comunicação ao excluir: %s\n' "$path"
      return 1
    }
    case "$status" in
      200) printf 'Excluído: %s\n' "$path" ;;
      *)
        printf 'Falha ao excluir "%s" (HTTP %s). Interrompendo.\n' "$path" "$status"
        jq -r '.message // empty' "$TMP_DIR/delete-folder-branch-result.json" 2>/dev/null
        return 1
        ;;
    esac
  done < "$TMP_DIR/delete-folder-branch-files.txt"
  printf '\nConteúdo da pasta "%s" excluído da BRANCH "%s".\n' "$folder" "$branch_name"
  printf 'Observação: o GitHub não armazena diretórios vazios; a pasta deixa de aparecer\n'
  printf 'quando todos os arquivos são removidos.\n'
}
rename_folder_secondary_branch() {
  local branch_name old_folder new_folder repo_encoded branch_ref_encoded branch_sha commit_tree_sha tree_status
  local old_prefix new_prefix confirm payload new_tree_sha new_commit_sha update_status
  ensure_login || return 1
  select_repository || return 1
  printf 'Nome da BRANCH secundária: '
  gui_read branch_name
  [ -n "$branch_name" ] || {
    printf 'Nome de branch inválido.\n'
    return 1
  }
  if [ "$branch_name" = "$DEFAULT_BRANCH" ]; then
    printf 'Operação bloqueada: renomeie pastas somente em uma BRANCH secundária.\n'
    return 1
  fi
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  branch_ref_encoded=$(urlencode_path "$branch_name") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/git/ref/heads/$branch_ref_encoded" "" "$TMP_DIR/rename-folder-branch-ref.json"; then
    printf 'A BRANCH secundária não foi localizada.\n'
    return 1
  fi
  branch_sha=$(jq -r '.object.sha // empty' "$TMP_DIR/rename-folder-branch-ref.json")
  [ -n "$branch_sha" ] || {
    printf 'Não foi possível obter o commit da BRANCH.\n'
    return 1
  }
  printf 'Caminho atual da pasta: '
  gui_read old_folder
  old_folder=$(printf '%s' "$old_folder" | sed 's#^/*##;s#/*$##')
  validate_remote_folder "$old_folder" || {
    printf 'Caminho atual inválido. Exemplo: docs/guias\n'
    return 1
  }
  printf 'Novo caminho da pasta: '
  gui_read new_folder
  new_folder=$(printf '%s' "$new_folder" | sed 's#^/*##;s#/*$##')
  validate_remote_folder "$new_folder" || {
    printf 'Novo caminho inválido. Exemplo: docs/manuais\n'
    return 1
  }
  [ "$old_folder" != "$new_folder" ] || {
    printf 'O caminho novo é igual ao atual. Nenhuma alteração realizada.\n'
    return 1
  }
  old_prefix="$old_folder/"
  new_prefix="$new_folder/"
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/git/commits/$branch_sha" "" "$TMP_DIR/rename-folder-commit.json"; then
    return 1
  fi
  commit_tree_sha=$(jq -r '.tree.sha // empty' "$TMP_DIR/rename-folder-commit.json")
  [ -n "$commit_tree_sha" ] || {
    printf 'Não foi possível obter a árvore da BRANCH.\n'
    return 1
  }
  tree_status=$(curl -sS -o "$TMP_DIR/rename-folder-tree.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/git/trees/$commit_tree_sha?recursive=1") || {
    printf 'Falha ao consultar a árvore da BRANCH.\n'
    return 1
  }
  [ "$tree_status" = 200 ] || {
    printf 'Falha ao consultar a árvore (HTTP %s).\n' "$tree_status"
    jq -r '.message // empty' "$TMP_DIR/rename-folder-tree.json" 2>/dev/null
    return 1
  }
  if [ "$(jq -r '.truncated // false' "$TMP_DIR/rename-folder-tree.json")" = true ]; then
    printf 'A árvore do repositório foi truncada pela API. Renomeação cancelada para evitar\n'
    printf 'alterações incompletas.\n'
    return 1
  fi
  if ! jq -e --arg prefix "$old_prefix" '.tree[]? | select(.type == "blob" and (.path | startswith($prefix)))' \
    "$TMP_DIR/rename-folder-tree.json" >/dev/null 2>&1; then
    printf 'A pasta atual não contém arquivos ou não foi encontrada: %s\n' "$old_folder"
    return 1
  fi
  if jq -e --arg prefix "$new_prefix" --arg exact "$new_folder" \
    '.tree[]? | select(.path == $exact or (.path | startswith($prefix)))' \
    "$TMP_DIR/rename-folder-tree.json" >/dev/null 2>&1; then
    printf 'O destino já existe: %s. Renomeação cancelada para evitar sobrescrita.\n' "$new_folder"
    return 1
  fi
  printf '\nRepositório     : %s\n' "$SELECTED_REPO"
  printf 'BRANCH secundária: %s\n' "$branch_name"
  printf 'Pasta atual     : %s\n' "$old_folder"
  printf 'Novo caminho    : %s\n' "$new_folder"
  printf 'Arquivos que serão movidos:\n'
  jq -r --arg prefix "$old_prefix" '.tree[]? | select(.type == "blob" and (.path | startswith($prefix))) | .path' \
    "$TMP_DIR/rename-folder-tree.json"
  printf '\nDigite RENOMEAR para confirmar: '
  gui_read confirm
  [ "$confirm" = RENOMEAR ] || {
    printf 'Operação cancelada.\n'
    return 0
  }
  payload=$(jq -c --arg old_prefix "$old_prefix" --arg new_prefix "$new_prefix" --arg base_tree "$commit_tree_sha" '
    {base_tree:$base_tree,tree:[
      (.tree[]? | select(.type == "blob" and (.path | startswith($old_prefix))) |
        {path:( $new_prefix + (.path | ltrimstr($old_prefix))),mode:.mode,type:"blob",sha:.sha}),
      (.tree[]? | select(.type == "blob" and (.path | startswith($old_prefix))) |
        {path:.path,mode:.mode,type:"blob",sha:null})
    ]}
  ' "$TMP_DIR/rename-folder-tree.json") || {
    printf 'Não foi possível preparar a árvore da renomeação.\n'
    return 1
  }
  if ! api POST "/repos/$GITHUB_USER/$repo_encoded/git/trees" "$payload" "$TMP_DIR/rename-folder-new-tree.json"; then
    printf 'Não foi possível criar a nova árvore. A BRANCH não foi alterada.\n'
    return 1
  fi
  new_tree_sha=$(jq -r '.sha // empty' "$TMP_DIR/rename-folder-new-tree.json")
  [ -n "$new_tree_sha" ] || {
    printf 'A API não retornou o SHA da nova árvore.\n'
    return 1
  }
  payload=$(jq -n \
    --arg message "Renomear pasta $old_folder para $new_folder" \
    --arg tree "$new_tree_sha" \
    --arg parent "$branch_sha" \
    '{message:$message,tree:$tree,parents:[$parent]}') || return 1
  if ! api POST "/repos/$GITHUB_USER/$repo_encoded/git/commits" "$payload" "$TMP_DIR/rename-folder-new-commit.json"; then
    printf 'Não foi possível criar o commit. A BRANCH não foi alterada.\n'
    return 1
  fi
  new_commit_sha=$(jq -r '.sha // empty' "$TMP_DIR/rename-folder-new-commit.json")
  [ -n "$new_commit_sha" ] || {
    printf 'A API não retornou o SHA do novo commit.\n'
    return 1
  }
  payload=$(jq -n --arg sha "$new_commit_sha" '{sha:$sha,force:false}') || return 1
  update_status=$(curl -sS -o "$TMP_DIR/rename-folder-update-ref.json" -w '%{http_code}' \
    -X PATCH \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    -H 'Content-Type: application/json' \
    --data-binary "$payload" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/git/refs/heads/$branch_ref_encoded") || {
    printf 'Falha de comunicação ao atualizar a BRANCH.\n'
    return 1
  }
  case "$update_status" in
    200)
      printf 'Pasta renomeada com sucesso: %s -> %s (BRANCH: %s)\n' "$old_folder" "$new_folder" "$branch_name"
      printf 'Os arquivos e subpastas foram preservados no novo caminho.\n'
      ;;
    *)
      printf 'Falha ao atualizar a BRANCH (HTTP %s). A árvore e o commit foram preparados,\n' "$update_status"
      printf 'mas a BRANCH não foi atualizada.\n'
      jq -r '.message // empty' "$TMP_DIR/rename-folder-update-ref.json" 2>/dev/null
      return 1
      ;;
  esac
}
compare_local_remote_file() {
  local file local_path local_date page count repo default_branch branch path
  local match_count selected_repo selected_branch selected_path encoded_repo encoded_path
  local remote_date remote_sha http_code temp_remote local_dir diff_status
  ensure_login || return 1
  local_dir="$(get_local_base_dir)" || return 1
  printf '\n=== COMPARAR ARQUIVO LOCAL COM REMOTO NO GITHUB ===\n'
  printf 'Diretório local configurado: %s\n' "$local_dir"
  printf 'Nome do arquivo local: '
  gui_read file
  case "$file" in
    ""|"."|".."|*/*|*\\*)
      printf 'Erro: informe somente o nome do arquivo, sem caminhos.\n'
      return 1
      ;;
  esac
  local_path="$local_dir/$file"
  if [ ! -f "$local_path" ] || [ ! -r "$local_path" ]; then
    printf 'Erro: arquivo local inexistente ou sem permissão de leitura: %s\n' "$local_path"
    return 1
  fi
  if ! command -v diff >/dev/null 2>&1 || ! command -v cmp >/dev/null 2>&1; then
    printf 'Erro: os comandos diff e cmp são necessários.\n'
    return 1
  fi
  local_date=$(stat -c '%y' "$local_path" 2>/dev/null || stat -f '%Sm' "$local_path" 2>/dev/null || printf 'indisponível')
  : > "$TMP_DIR/compare-matches.tsv"
  page=1
  while :; do
    if ! api GET "/user/repos?affiliation=owner&per_page=100&page=$page&sort=full_name" "" "$TMP_DIR/compare-repos.json"; then
      return 1
    fi
    count=$(jq 'length' "$TMP_DIR/compare-repos.json" 2>/dev/null)
    case "$count" in ''|*[!0-9]*) printf 'Resposta inválida da API ao listar repositórios.\n'; return 1 ;; esac
    [ "$count" -gt 0 ] || break
    while IFS="$(printf '\t')" read -r repo default_branch; do
      [ -n "$repo" ] || continue
      if ! api GET "/repos/$GITHUB_USER/$(urlencode "$repo")/branches?per_page=100" "" "$TMP_DIR/compare-branches.json"; then
        continue
      fi
      while IFS= read -r branch; do
        [ -n "$branch" ] || continue
        if ! api GET "/repos/$GITHUB_USER/$(urlencode "$repo")/git/trees/$(urlencode "$branch")?recursive=1" "" "$TMP_DIR/compare-tree.json"; then
          continue
        fi
        jq -r --arg file "$file" --arg repo "$repo" --arg branch "$branch" '
          .tree[]? | select(.type == "blob") | select((.path | split("/") | last) == $file) | [$repo,$branch,.path] | @tsv
        ' "$TMP_DIR/compare-tree.json" >> "$TMP_DIR/compare-matches.tsv"
      done < <(jq -r '.[].name' "$TMP_DIR/compare-branches.json" 2>/dev/null)
    done < <(jq -r '.[] | [.name,.default_branch] | @tsv' "$TMP_DIR/compare-repos.json")
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
  done
  match_count=$(wc -l < "$TMP_DIR/compare-matches.tsv" | tr -d ' ')
  if [ "$match_count" -eq 0 ]; then
    printf '\nArquivo remoto não encontrado no GitHub: %s\n' "$file"
    return 1
  fi
  IFS="$(printf '\t')" read -r selected_repo selected_branch selected_path < "$TMP_DIR/compare-matches.tsv"
  if [ "$match_count" -gt 1 ]; then
    printf '\nAVISO: foram encontrados %s arquivos remotos com esse nome.\n' "$match_count"
    printf 'Será comparada a primeira correspondência abaixo; resultados encontrados:\n'
    while IFS="$(printf '\t')" read -r repo branch path; do
      printf '  %s | branch: %s | caminho: %s\n' "$repo" "$branch" "$path"
    done < "$TMP_DIR/compare-matches.tsv"
  fi
  encoded_repo=$(urlencode "$selected_repo") || return 1
  encoded_path=$(urlencode_path "$selected_path") || return 1
  http_code=$(curl -sS -o "$TMP_DIR/compare-content.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$encoded_repo/contents/$encoded_path?ref=$(urlencode "$selected_branch")") || return 1
  if [ "$http_code" != 200 ]; then
    printf 'Erro ao baixar arquivo remoto (HTTP %s).\n' "$http_code"
    jq -r '.message // empty' "$TMP_DIR/compare-content.json" 2>/dev/null
    return 1
  fi
  if [ "$(jq -r '.type // empty' "$TMP_DIR/compare-content.json")" != "file" ]; then
    printf 'O resultado remoto não é um arquivo.\n'
    return 1
  fi
  temp_remote="$TMP_DIR/remote-file"
  if ! jq -r '.content // empty' "$TMP_DIR/compare-content.json" | tr -d '\n' | base64 -d > "$temp_remote"; then
    printf 'Não foi possível decodificar o conteúdo remoto.\n'
    return 1
  fi
  remote_date=$(api GET "/repos/$GITHUB_USER/$encoded_repo/commits?path=$encoded_path&sha=$(urlencode "$selected_branch")&per_page=1" "" "$TMP_DIR/compare-commits.json" && jq -r '.[0].commit.committer.date // .[0].commit.author.date // "indisponível"' "$TMP_DIR/compare-commits.json" 2>/dev/null)
  [ -n "$remote_date" ] || remote_date='indisponível'
  printf '\n============================================================\n'
  printf 'ARQUIVO LOCAL  : %s\n' "$local_path"
  printf 'DATA LOCAL     : %s\n' "$local_date"
  printf 'ARQUIVO REMOTO : %s/%s\n' "$GITHUB_USER" "$selected_repo"
  printf 'BRANCH REMOTA  : %s\n' "$selected_branch"
  printf 'CAMINHO REMOTO : %s\n' "$selected_path"
  printf 'DATA REMOTA    : %s (último commit)\n' "$remote_date"
  printf '============================================================\n'
  if cmp -s "$local_path" "$temp_remote"; then
    printf '\n╔══════════════════════════════════════════╗\n'
    printf '║             ARQUIVOS IGUAIS!             ║\n'
    printf '╚══════════════════════════════════════════╝\n'
    return 0
  fi
  printf '\nDIFERENÇAS ENCONTRADAS (LOCAL = - ; REMOTO = +):\n\n'
  if diff -u --label "LOCAL: $file" --label "REMOTO: $selected_repo/$selected_path ($selected_branch)" "$local_path" "$temp_remote"; then
    :
  else
    diff_status=$?
    if [ "$diff_status" -gt 1 ]; then
      printf 'Não foi possível gerar a comparação textual; o arquivo pode ser binário.\n'
      return 1
    fi
  fi
  return 0
}
upload_selected_attachments() {
  local attachments_json="${GITHUB_ATTACHMENTS_JSON:-[]}"
  local count index file remote_path encoded_repo encoded_path sha http_code answer failed=0 sent=0
  ensure_login || return 1
  command -v base64 >/dev/null 2>&1 || { printf 'Erro: base64 não está disponível.\n'; return 1; }
  count=$(jq 'length' <<< "$attachments_json" 2>/dev/null) || { printf 'Lista de anexos inválida.\n'; return 1; }
  (( count > 0 )) || { printf 'Nenhum arquivo foi selecionado.\n'; return 1; }
  printf '\n=== ENVIAR %s ARQUIVO(S) ANEXO(S) AO GITHUB ===\n' "$count"
  printf 'Diretório local configurado: %s\n' "$(get_local_base_dir)"
  select_repository || return 1
  encoded_repo=$(urlencode "$SELECTED_REPO") || return 1
  for ((index=0; index<count; index++)); do
    file=$(jq -r ".[$index]" <<< "$attachments_json") || { failed=$((failed+1)); continue; }
    if [[ ! -f "$file" || -L "$file" || ! -r "$file" ]]; then
      printf '[FALHA] Arquivo inexistente ou sem leitura: %s\n' "$file"; failed=$((failed+1)); continue
    fi
    remote_path="$(basename -- "$file")"
    encoded_path=$(urlencode_path "$remote_path") || { failed=$((failed+1)); continue; }
    if ! base64 < "$file" | tr -d '\r\n' > "$TMP_DIR/upload-content.b64"; then
      printf '[FALHA] Não foi possível ler/codificar: %s\n' "$file"; failed=$((failed+1)); continue
    fi
    http_code=$(curl -sS -o "$TMP_DIR/content.json" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "$API_URL/repos/$GITHUB_USER/$encoded_repo/contents/$encoded_path?ref=$(urlencode "$DEFAULT_BRANCH")") || http_code=000
    sha=""
    case "$http_code" in
      200) sha=$(jq -r '.sha // empty' "$TMP_DIR/content.json");;
      404) ;;
      *) printf '[FALHA] Consulta de %s (HTTP %s).\n' "$remote_path" "$http_code"; failed=$((failed+1)); continue;;
    esac
    if [[ -n "$sha" ]]; then
      printf 'O arquivo remoto %s já existe. Atualizar? (s/n): ' "$remote_path"
      gui_read answer
      case "$answer" in s|S|sim|SIM) ;; *) printf '[IGNORADO] %s\n' "$remote_path"; continue;; esac
    fi
    if ! jq -n --arg message "Envio de $remote_path via GitHub Manager" --rawfile content "$TMP_DIR/upload-content.b64" \
      --arg branch "$DEFAULT_BRANCH" --arg sha "$sha" \
      '{message:$message,content:($content|gsub("[\\r\\n]";"")),branch:$branch} + (if $sha != "" then {sha:$sha} else {} end)' > "$TMP_DIR/upload-payload.json"; then
      printf '[FALHA] Preparação do envio: %s\n' "$remote_path"; failed=$((failed+1)); continue
    fi
    http_code=$(curl -sS -o "$TMP_DIR/upload.json" -w '%{http_code}' -X PUT \
      -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" -H 'Content-Type: application/json' \
      --data-binary "@$TMP_DIR/upload-payload.json" \
      "$API_URL/repos/$GITHUB_USER/$encoded_repo/contents/$encoded_path") || http_code=000
    if [[ "$http_code" == 200 || "$http_code" == 201 ]] && jq -e '.content.sha and .commit.sha' "$TMP_DIR/upload.json" >/dev/null 2>&1; then
      printf '[OK] Enviado: %s\n' "$file"; sent=$((sent+1))
    else
      printf '[FALHA] %s (HTTP %s): %s\n' "$remote_path" "$http_code" "$(jq -r '.message // "sem detalhes"' "$TMP_DIR/upload.json" 2>/dev/null)"; failed=$((failed+1))
    fi
  done
  printf '\nRESUMO: %s enviado(s), %s com falha, %s selecionado(s).\n' "$sent" "$failed" "$count"
  (( failed == 0 ))
}
LOCAL_DIR_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/github-manager/current-directory"
get_local_base_dir() {
  local saved_dir=""
  if [[ -r "$LOCAL_DIR_CONFIG" ]]; then
    IFS= read -r saved_dir < "$LOCAL_DIR_CONFIG" || true
  fi
  if [[ -n "$saved_dir" && -d "$saved_dir" ]]; then
    (cd -- "$saved_dir" 2>/dev/null && pwd -P) || pwd -P
  else
    pwd -P
  fi
}
list_local_files() {
  local local_dir
  local_dir="$(get_local_base_dir)" || return 1
  printf '\nDiretório local configurado: %s\n' "$local_dir"
  if ! find "$local_dir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort; then
    printf 'Não foi possível listar os arquivos de: %s\n' "$local_dir"
    return 1
  fi
}
change_current_directory() {
  local requested_dir resolved_dir config_dir temp_config
  local current_dir
  current_dir="$(get_local_base_dir)" || current_dir="$PWD"
  printf 'Diretório atual configurado: %s\nNovo diretório: ' "$current_dir"
  gui_read requested_dir
  [ -n "$requested_dir" ] || { printf 'Diretório não informado.\n'; return 1; }
  case "$requested_dir" in
    '~') requested_dir="$HOME" ;;
    '~/'*) requested_dir="$HOME/${requested_dir#\~/}" ;;
    /*) ;;
    *) requested_dir="$current_dir/$requested_dir" ;;
  esac
  [ -d "$requested_dir" ] || { printf 'Diretório não encontrado: %s\n' "$requested_dir"; return 1; }
  resolved_dir="$(cd -- "$requested_dir" 2>/dev/null && pwd -P)" || {
    printf 'Não foi possível acessar o diretório informado.\n'
    return 1
  }
  config_dir="$(dirname "$LOCAL_DIR_CONFIG")"
  mkdir -p "$config_dir" || { printf 'Não foi possível criar a configuração local.\n'; return 1; }
  temp_config="$(mktemp "$config_dir/.current-directory.XXXXXX")" || return 1
  if ! printf '%s\n' "$resolved_dir" > "$temp_config" || ! chmod 600 "$temp_config" || ! mv -f -- "$temp_config" "$LOCAL_DIR_CONFIG"; then
    rm -f -- "$temp_config"
    printf 'Falha ao salvar o diretório local. A configuração anterior foi preservada.\n'
    return 1
  fi
  printf 'Diretório local alterado e salvo: %s\n' "$resolved_dir"
  printf 'As tarefas que usam arquivos locais (comparar, enviar, baixar, listar e anexos)\n'
  printf 'utilizarão este caminho mesmo após fechar e reabrir o aplicativo.\n'
}
search_file() {
  local page count repo default_branch branch path search_term
  ensure_login || return 1
  printf 'Nome ou trecho do nome do arquivo: '
  gui_read search_term
  [ -n "$search_term" ] || {
    printf 'Termo de pesquisa inválido.\n'
    return 1
  }
  page=1
  while :; do
    if ! api GET \
      "/user/repos?affiliation=owner&per_page=100&page=$page&sort=full_name" \
      "" "$TMP_DIR/repos.json"; then
      return 1
    fi
    count=$(jq 'length' "$TMP_DIR/repos.json")
    [ "$count" -gt 0 ] || break
    while IFS="$(printf '\t')" read -r repo default_branch; do
      [ -n "$repo" ] || continue
      if ! api GET \
        "/repos/$GITHUB_USER/$(urlencode "$repo")/branches?per_page=100" \
        "" "$TMP_DIR/branches.json"; then
        continue
      fi
      while IFS= read -r branch; do
        [ -n "$branch" ] || continue
        if ! api GET \
          "/repos/$GITHUB_USER/$(urlencode "$repo")/git/trees/$(urlencode "$branch")?recursive=1" \
          "" "$TMP_DIR/tree.json"; then
          continue
        fi
        jq -r --arg term "$search_term" '
          .tree[]?
          | select(.type == "blob")
          | select(.path | ascii_downcase | contains($term | ascii_downcase))
          | .path
        ' "$TMP_DIR/tree.json" |
        while IFS= read -r path; do
          printf 'Repositório: %s | Branch: %s | Caminho: %s\n' \
            "$repo" "$branch" "$path"
        done
      done < <(jq -r '.[].name' "$TMP_DIR/branches.json")
    done < <(
      jq -r '.[] | [.name,.default_branch] | @tsv' "$TMP_DIR/repos.json"
    )
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
  done
}
clone_third_party_repository() {
  local url destination destination_parent
  command -v git >/dev/null 2>&1 || {
    printf 'Git não está instalado.\n'
    return 1
  }
  printf 'URL HTTPS ou SSH do repositório: '
  gui_read url
  [ -n "$url" ] || {
    printf 'URL inválida.\n'
    return 1
  }
  case "$url" in
    https://*|ssh://*|git@*:* ) ;;
    *) printf 'Origem bloqueada: use somente URL HTTPS ou SSH. Caminhos locais e protocolos auxiliares não são aceitos.\n'; return 1 ;;
  esac
  printf 'Diretório de destino (ENTER para usar o padrão): '
  gui_read destination
  if [ -n "$destination" ]; then
    case "$destination" in
      /*) ;;
      *) destination="$PWD/$destination" ;;
    esac
    destination_parent="$(dirname -- "$destination")"
    [[ -d "$destination_parent" && ! -L "$destination_parent" ]] || { printf 'Pasta pai do destino inexistente ou simbólica.\n'; return 1; }
    [[ ! -e "$destination" && ! -L "$destination" ]] || { printf 'O destino já existe. Clone cancelado para evitar sobrescrita.\n'; return 1; }
    git clone -- "$url" "$destination"
  else
    git clone -- "$url"
  fi
}

delete_repository() {
  local name answer
  ensure_login || return 1
  printf 'Nome do repositório a excluir: '
  gui_read name
  valid_name "$name" || {
    printf 'Nome inválido.\n'
    return 1
  }
  printf 'ATENÇÃO: excluir permanentemente %s/%s? (s/n): ' "$GITHUB_USER" "$name"
  gui_read answer
  case "$answer" in
    s|S|sim|SIM) ;;
    *) printf 'Operação cancelada.\n'; return 0 ;;
  esac
  if api DELETE "/repos/$GITHUB_USER/$(urlencode "$name")"; then
    printf 'Repositório excluído.\n'
    audit_log "DELETE_REPO" "$GITHUB_USER/$name"
  fi
}
rename_repository() {
  local old_name new_name payload
  ensure_login || return 1
  printf 'Nome atual do repositório: '
  gui_read old_name
  valid_name "$old_name" || {
    printf 'Nome inválido.\n'
    return 1
  }
  printf 'Novo nome do repositório: '
  gui_read new_name
  valid_name "$new_name" || {
    printf 'Novo nome inválido.\n'
    return 1
  }
  payload=$(jq -n --arg name "$new_name" '{name:$name}')
  if api PATCH "/repos/$GITHUB_USER/$(urlencode "$old_name")" "$payload"; then
    printf 'Repositório renomeado para: %s\n' "$new_name"
  fi
}

remote_file_paths() {
  local repo="$1" branch="$2" folder="$3" repo_encoded branch_encoded prefix
  repo_encoded=$(urlencode "$repo") || return 1
  branch_encoded=$(urlencode "$branch") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/git/trees/$branch_encoded?recursive=1" "" "$TMP_DIR/remote-files-tree.json"; then return 1; fi
  if [ "$(jq -r '.truncated // false' "$TMP_DIR/remote-files-tree.json")" = "true" ]; then
    printf 'AVISO: a árvore retornada pelo GitHub está truncada; a lista pode estar incompleta.\n'
  fi
  if [ -n "$folder" ]; then
    prefix="$folder/"
    jq -r --arg prefix "$prefix" '.tree[]? | select(.type == "blob") | select(.path | startswith($prefix)) | .path' "$TMP_DIR/remote-files-tree.json" > "$TMP_DIR/remote-files-paths.txt"
  else
    jq -r '.tree[]? | select(.type == "blob") | .path' "$TMP_DIR/remote-files-tree.json" > "$TMP_DIR/remote-files-paths.txt"
  fi
}

choose_repository_branch() {
  local mode="$1" repo repo_encoded branch
  printf 'Nome do repositório: '
  gui_read repo
  valid_name "$repo" || { printf 'Nome de repositório inválido.\n'; return 1; }
  repo_encoded=$(urlencode "$repo") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded" "" "$TMP_DIR/move-repo.json"; then return 1; fi
  DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$TMP_DIR/move-repo.json")
  if [ "$mode" = "main" ]; then
    branch="$DEFAULT_BRANCH"
    printf 'Usando MAIN: %s\n' "$branch"
  else
    printf 'Nome da BRANCH secundária: '
    gui_read branch
    [ -n "$branch" ] || { printf 'Informe uma BRANCH secundária.\n'; return 1; }
    [ "$branch" != "$DEFAULT_BRANCH" ] || { printf 'A branch informada é a MAIN, não uma branch secundária.\n'; return 1; }
    if ! api GET "/repos/$GITHUB_USER/$repo_encoded/branches/$(urlencode "$branch")" "" "$TMP_DIR/move-branch.json"; then return 1; fi
  fi
  SELECTED_REPO="$repo"
  SELECTED_BRANCH="$branch"
}

list_remote_folder_files() {
  local mode="$1" folder total
  ensure_login || return 1
  if [ "$mode" = "main" ]; then printf '\n=== ARQUIVOS DA MAIN ===\n'; else printf '\n=== ARQUIVOS DA BRANCH SECUNDÁRIA ===\n'; fi
  choose_repository_branch "$mode" || return 1
  printf 'Caminho da pasta (ENTER para RAIZ): '
  gui_read folder
  folder=${folder#/}; folder=${folder%/}
  if [ -n "$folder" ]; then validate_remote_folder "$folder" || { printf 'Caminho de pasta inválido.\n'; return 1; }; fi
  remote_file_paths "$SELECTED_REPO" "$SELECTED_BRANCH" "$folder" || return 1
  total=$(wc -l < "$TMP_DIR/remote-files-paths.txt" | tr -d ' ')
  if [ "$total" -eq 0 ]; then printf 'Nenhum arquivo encontrado.\n'; return 0; fi
  printf '\nRepositório : %s\n' "$SELECTED_REPO"
  printf 'Branch      : %s\n' "$SELECTED_BRANCH"
  printf 'Pasta       : %s\n' "${folder:-/}"
  printf 'Arquivos encontrados: %s\n' "$total"
  cat "$TMP_DIR/remote-files-paths.txt"
}

move_remote_files() {
  local mode="$1" source_folder destination_folder repo_encoded branch_encoded
  local source_path relative_path destination_path source_encoded destination_encoded
  local source_sha target_status target_sha answer payload status
  local requested_file matched_path candidate
  ensure_login || return 1
  if [ "$mode" = "main" ]; then printf '\n=== MOVER ARQUIVO NA MAIN ===\n'; else printf '\n=== MOVER ARQUIVO NA BRANCH SECUNDÁRIA ===\n'; fi
  choose_repository_branch "$mode" || return 1
  printf 'Caminho da pasta de ORIGEM (ENTER para RAIZ): '
  gui_read source_folder
  source_folder=${source_folder#/}; source_folder=${source_folder%/}
  if [ -n "$source_folder" ]; then validate_remote_folder "$source_folder" || { printf 'Caminho de origem inválido.\n'; return 1; }; fi
  remote_file_paths "$SELECTED_REPO" "$SELECTED_BRANCH" "$source_folder" || return 1
  if [ ! -s "$TMP_DIR/remote-files-paths.txt" ]; then printf 'Nenhum arquivo encontrado na origem.\n'; return 0; fi
  printf '\nArquivos disponíveis na origem:\n'
  cat "$TMP_DIR/remote-files-paths.txt"
  printf '\nInforme o NOME do arquivo a mover (com extensão, sem caminho): '
  gui_read requested_file
  [ -n "$requested_file" ] || { printf 'Nome de arquivo não informado.\n'; return 1; }
  case "$requested_file" in */*|*\\*) printf 'Informe somente o nome do arquivo, sem caminhos.\n'; return 1 ;; esac
  matched_path=""
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ "${candidate##*/}" = "$requested_file" ]; then
      matched_path="$candidate"
      break
    fi
  done < "$TMP_DIR/remote-files-paths.txt"
  if [ -z "$matched_path" ]; then
    printf 'Arquivo "%s" não encontrado na pasta de origem.\n' "$requested_file"
    return 1
  fi
  source_path="$matched_path"
  printf '\nArquivo selecionado: %s\n' "$source_path"
  printf 'Caminho da pasta de DESTINO (ENTER para RAIZ): '
  gui_read destination_folder
  destination_folder=${destination_folder#/}; destination_folder=${destination_folder%/}
  if [ -n "$destination_folder" ]; then validate_remote_folder "$destination_folder" || { printf 'Caminho de destino inválido.\n'; return 1; }; fi
  if [ -n "$source_folder" ]; then relative_path=${source_path#"$source_folder"/}; else relative_path="$source_path"; fi
  if [ -n "$destination_folder" ]; then destination_path="$destination_folder/$relative_path"; else destination_path="$relative_path"; fi
  if [ "$source_path" = "$destination_path" ]; then printf 'Origem e destino são iguais; nada a mover.\n'; return 0; fi
  printf '\nOrigem  : %s\n' "$source_path"
  printf 'Destino : %s\n' "$destination_path"
  printf 'Confirma mover este arquivo? (s/n): '
  gui_read answer
  case "$answer" in s|S|sim|SIM) ;; *) printf 'Operação cancelada.\n'; return 0 ;; esac
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  branch_encoded=$(urlencode "$SELECTED_BRANCH") || return 1
  source_encoded=$(urlencode_path "$source_path") || { printf 'Falha ao codificar origem.\n'; return 1; }
  destination_encoded=$(urlencode_path "$destination_path") || { printf 'Falha ao codificar destino.\n'; return 1; }
  status=$(curl -sS -o "$TMP_DIR/move-source.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$source_encoded?ref=$branch_encoded") || status=000
  if [ "$status" != 200 ]; then printf 'Falha ao ler origem: %s (HTTP %s)\n' "$source_path" "$status"; return 1; fi
  source_sha=$(jq -r '.sha // empty' "$TMP_DIR/move-source.json")
  if [ -z "$source_sha" ] || ! jq -e '.content and (.encoding == "base64")' "$TMP_DIR/move-source.json" >/dev/null 2>&1; then
    printf 'Não foi possível obter conteúdo/SHA de %s.\n' "$source_path"; return 1
  fi
  jq -r '.content' "$TMP_DIR/move-source.json" | tr -d '\r\n' > "$TMP_DIR/move-content.b64" || { printf 'Falha ao preparar conteúdo.\n'; return 1; }
  target_status=$(curl -sS -o "$TMP_DIR/move-target.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$destination_encoded?ref=$branch_encoded") || target_status=000
  target_sha=""
  case "$target_status" in
    200)
      target_sha=$(jq -r '.sha // empty' "$TMP_DIR/move-target.json")
      printf '\nDestino já existe: %s\n' "$destination_path"
      printf 'Digite A para ATUALIZAR o destino ou M para MANTER o destino e cancelar: '
      gui_read answer
      case "$answer" in A|a|ATUALIZA|atualiza) ;; *) printf 'Destino mantido; origem preservada: %s\n' "$source_path"; return 0 ;; esac
      [ -n "$target_sha" ] || { printf 'SHA do destino indisponível.\n'; return 1; }
      ;;
    404) ;;
    *) printf 'Falha ao verificar destino %s (HTTP %s).\n' "$destination_path" "$target_status"; return 1 ;;
  esac
  if ! jq -n --arg message "Mover $source_path para $destination_path via GitHub Manager" \
    --rawfile content "$TMP_DIR/move-content.b64" --arg branch "$SELECTED_BRANCH" --arg sha "$target_sha" \
    '{message:$message,content:$content,branch:$branch} + (if $sha != "" then {sha:$sha} else {} end)' \
    > "$TMP_DIR/move-upload-payload.json"; then
    printf 'Falha ao preparar destino: %s\n' "$destination_path"; return 1
  fi
  status=$(curl -sS -o "$TMP_DIR/move-upload.json" -w '%{http_code}' -X PUT \
    -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" -H 'Content-Type: application/json' \
    --data-binary "@$TMP_DIR/move-upload-payload.json" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$destination_encoded") || status=000
  case "$status" in 200|201) ;; *) printf 'Falha ao gravar destino %s (HTTP %s); origem preservada.\n' "$destination_path" "$status"; return 1 ;; esac
  payload=$(jq -n --arg message "Remover origem após mover para $destination_path" --arg sha "$source_sha" --arg branch "$SELECTED_BRANCH" '{message:$message,sha:$sha,branch:$branch}') || { printf 'Destino gravado, mas não foi possível preparar a remoção da origem.\n'; return 1; }
  status=$(curl -sS -o "$TMP_DIR/move-delete.json" -w '%{http_code}' -X DELETE \
    -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" -H 'Content-Type: application/json' \
    --data-binary "$payload" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$source_encoded") || status=000
  if [ "$status" = 200 ] || [ "$status" = 204 ]; then
    printf '\nMovido com sucesso: %s -> %s\n' "$source_path" "$destination_path"
  else
    printf 'Destino gravado, mas falhou a remoção da origem %s (HTTP %s).\n' "$source_path" "$status"
    printf 'Verifique antes de repetir.\n'
    return 1
  fi
}
list_main_repository_files() { list_remote_folder_files "main"; }
list_secondary_branch_files() { list_remote_folder_files "secondary"; }
move_main_repository_files() { move_remote_files "main"; }
move_secondary_branch_files() { move_remote_files "secondary"; }

# Move arquivos em lote mantendo o nome-base de cada arquivo no diretório destino.
# Cada arquivo só é removido da origem depois que o upload ao destino é confirmado.
move_all_files_bulk() {
  local mode="$1" source_folder="${2:-}" destination_folder repo branch repo_encoded branch_encoded
  local source_path base_name destination_path source_encoded destination_encoded
  local source_status source_sha target_status target_sha payload status total moved failed answer i
  local -a paths=() destinations=()
  ensure_login || return 1
  printf '\n=== MOVIMENTAÇÃO EM LOTE DE ARQUIVOS ===\n'
  printf 'Nome do repositório: '
  gui_read repo
  valid_name "$repo" || { printf 'Nome de repositório inválido.\n'; return 1; }
  repo_encoded=$(urlencode "$repo") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded" "" "$TMP_DIR/bulk-repo.json"; then return 1; fi
  printf 'Nome exato da branch (ex.: main): '
  gui_read branch
  [ -n "$branch" ] || { printf 'Branch não informada.\n'; return 1; }
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/branches/$(urlencode "$branch")" "" "$TMP_DIR/bulk-branch.json"; then
    printf 'A branch "%s" não foi encontrada ou não está acessível.\n' "$branch"
    return 1
  fi
  DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$TMP_DIR/bulk-repo.json")
  if [ "$mode" = "main" ] && [ "$branch" != "$DEFAULT_BRANCH" ]; then
    printf 'Esta opção exige a branch principal do repositório: %s\n' "$DEFAULT_BRANCH"; return 1
  fi
  if [ "$mode" = "secondary" ] && [ "$branch" = "$DEFAULT_BRANCH" ]; then
    printf 'Esta opção exige uma branch secundária, diferente de %s.\n' "$DEFAULT_BRANCH"; return 1
  fi
  SELECTED_REPO="$repo"; SELECTED_BRANCH="$branch"
  if [ "$mode" = "folder" ] || [ "$mode" = "main" ]; then
    printf 'Diretório de ORIGEM no repositório (ENTER para RAIZ): '
    gui_read source_folder
    source_folder=${source_folder#/}; source_folder=${source_folder%/}
    if [ -n "$source_folder" ]; then
      validate_remote_folder "$source_folder" || { printf 'Diretório de origem inválido.\n'; return 1; }
    else
      source_folder=""
      printf 'Pasta de origem: RAIZ do repositório.\n'
    fi
  else
    source_folder=""
    printf 'Operação selecionada para os arquivos da branch secundária informada.\n'
  fi
  printf 'Diretório de DESTINO no repositório: '
  gui_read destination_folder
  destination_folder=${destination_folder#/}; destination_folder=${destination_folder%/}
  if [ -n "$destination_folder" ]; then
    validate_remote_folder "$destination_folder" || { printf 'Diretório de destino inválido.\n'; return 1; }
  fi
  if [ -n "$source_folder" ] && { [ "$destination_folder" = "$source_folder" ] || [[ "$destination_folder" == "$source_folder/"* ]]; }; then
    printf 'Destino não pode ser a própria origem nem uma subpasta dela.\n'; return 1
  fi
  remote_file_paths "$SELECTED_REPO" "$SELECTED_BRANCH" "$source_folder" || return 1
  if [ "$(jq -r '.truncated // false' "$TMP_DIR/remote-files-tree.json")" = "true" ]; then
    printf 'A listagem da árvore do GitHub veio truncada. Operação cancelada para evitar mover apenas parte dos arquivos.\n'
    return 1
  fi
  while IFS= read -r source_path; do
    [ -n "$source_path" ] || continue
    base_name=${source_path##*/}
    [ -n "$destination_folder" ] && destination_path="$destination_folder/$base_name" || destination_path="$base_name"
    [ "$source_path" = "$destination_path" ] && continue
    paths+=("$source_path")
    destinations+=("$destination_path")
  done < "$TMP_DIR/remote-files-paths.txt"
  total=${#paths[@]}
  if [ "$total" -eq 0 ]; then printf 'Nenhum arquivo elegível foi encontrado.\n'; return 0; fi
  # Impede colisões de nomes quando arquivos de subpastas diferentes têm o mesmo basename.
  local -A seen_dest=()
  for destination_path in "${destinations[@]}"; do
    if [[ -n "${seen_dest[$destination_path]+x}" ]]; then
      printf 'Colisão: mais de um arquivo seria gravado como "%s". Nenhuma alteração foi feita.\n' "$destination_path"
      return 1
    fi
    seen_dest[$destination_path]=1
  done
  # Pré-valida TODOS os destinos antes de alterar qualquer arquivo.
  for destination_path in "${destinations[@]}"; do
    destination_encoded=$(urlencode_path "$destination_path") || return 1
    target_status=$(curl -sS -o "$TMP_DIR/bulk-preflight.json" -w '%{http_code}' -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GITHUB_TOKEN" -H "X-GitHub-Api-Version: $API_VERSION" "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$destination_encoded?ref=$(urlencode "$SELECTED_BRANCH")") || target_status=000
    case "$target_status" in
      404) ;;
      200) printf 'Destino já existe: %s. Nenhum arquivo foi alterado. Escolha outra pasta de destino.\n' "$destination_path"; return 1 ;;
      *) printf 'Não foi possível validar o destino %s (HTTP %s). Nenhum arquivo foi alterado.\n' "$destination_path" "$target_status"; return 1 ;;
    esac
  done
  printf '\nRepositório: %s\nBranch: %s\nArquivos selecionados: %s\nDestino: %s\n' "$SELECTED_REPO" "$SELECTED_BRANCH" "$total" "${destination_folder:-/}"
  printf '\nPrévia da movimentação:\n'
  for ((i=0; i<total; i++)); do printf '  %s  ->  %s\n' "${paths[$i]}" "${destinations[$i]}"; done
  printf '\nConfirma mover TODOS os arquivos listados? (s/n): '
  gui_read answer
  case "$answer" in s|S|sim|SIM) ;; *) printf 'Operação cancelada.\n'; return 0 ;; esac
  branch_encoded=$(urlencode "$SELECTED_BRANCH") || return 1
  moved=0; failed=0
  for ((i=0; i<total; i++)); do
    source_path=${paths[$i]}; destination_path=${destinations[$i]}
    source_encoded=$(urlencode_path "$source_path") || { printf 'Falha ao codificar origem: %s\n' "$source_path"; failed=$((failed+1)); continue; }
    destination_encoded=$(urlencode_path "$destination_path") || { printf 'Falha ao codificar destino: %s\n' "$destination_path"; failed=$((failed+1)); continue; }
    source_status=$(curl -sS -o "$TMP_DIR/bulk-source.json" -w '%{http_code}' -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GITHUB_TOKEN" -H "X-GitHub-Api-Version: $API_VERSION" "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$source_encoded?ref=$branch_encoded") || source_status=000
    if [ "$source_status" != 200 ]; then printf '[FALHA] Leitura de %s (HTTP %s).\n' "$source_path" "$source_status"; failed=$((failed+1)); continue; fi
    source_sha=$(jq -r '.sha // empty' "$TMP_DIR/bulk-source.json")
    if [ -z "$source_sha" ] || ! jq -e '.content and (.encoding == "base64")' "$TMP_DIR/bulk-source.json" >/dev/null 2>&1; then
      printf '[FALHA] Conteúdo não disponível pela API (possível arquivo acima do limite de Contents API): %s\n' "$source_path"; failed=$((failed+1)); continue
    fi
    jq -r '.content' "$TMP_DIR/bulk-source.json" | tr -d '\r\n' > "$TMP_DIR/bulk-content.b64" || { failed=$((failed+1)); continue; }
    target_status=$(curl -sS -o "$TMP_DIR/bulk-target.json" -w '%{http_code}' -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GITHUB_TOKEN" -H "X-GitHub-Api-Version: $API_VERSION" "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$destination_encoded?ref=$branch_encoded") || target_status=000
    target_sha=""
    case "$target_status" in
      404) ;;
      200) printf '[PULADO] O destino já existe: %s (nenhum arquivo será sobrescrito).\n' "$destination_path"; failed=$((failed+1)); continue ;;
      *) printf '[FALHA] Verificação do destino %s (HTTP %s).\n' "$destination_path" "$target_status"; failed=$((failed+1)); continue ;;
    esac
    if ! jq -n --arg message "Mover $source_path para $destination_path" --rawfile content "$TMP_DIR/bulk-content.b64" --arg branch "$SELECTED_BRANCH" '{message:$message,content:$content,branch:$branch}' > "$TMP_DIR/bulk-upload.json"; then failed=$((failed+1)); continue; fi
    status=$(curl -sS -o "$TMP_DIR/bulk-upload-result.json" -w '%{http_code}' -X PUT -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GITHUB_TOKEN" -H "X-GitHub-Api-Version: $API_VERSION" -H 'Content-Type: application/json' --data-binary "@$TMP_DIR/bulk-upload.json" "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$destination_encoded") || status=000
    case "$status" in 200|201) ;; *) printf '[FALHA] Upload de %s (HTTP %s); origem preservada.\n' "$destination_path" "$status"; failed=$((failed+1)); continue ;; esac
    payload=$(jq -n --arg message "Remover origem após movimentação para $destination_path" --arg sha "$source_sha" --arg branch "$SELECTED_BRANCH" '{message:$message,sha:$sha,branch:$branch}') || { printf '[ATENÇÃO] Destino gravado; falha ao preparar remoção de %s.\n' "$source_path"; failed=$((failed+1)); continue; }
    status=$(curl -sS -o "$TMP_DIR/bulk-delete-result.json" -w '%{http_code}' -X DELETE -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GITHUB_TOKEN" -H "X-GitHub-Api-Version: $API_VERSION" -H 'Content-Type: application/json' --data-binary "$payload" "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$source_encoded") || status=000
    if [ "$status" = 200 ] || [ "$status" = 204 ]; then printf '[OK] %s -> %s\n' "$source_path" "$destination_path"; moved=$((moved+1)); else printf '[ATENÇÃO] Destino gravado, mas origem não removida: %s (HTTP %s).\n' "$source_path" "$status"; failed=$((failed+1)); fi
  done
  printf '\nRESUMO: %s movido(s), %s com falha/ignorados, de %s arquivo(s).\n' "$moved" "$failed" "$total"
  [ "$failed" -eq 0 ]
}
move_all_repository_folder_files() { move_all_files_bulk "folder"; }
move_all_main_branch_files() { move_all_files_bulk "main"; }
move_all_secondary_branch_files() { move_all_files_bulk "secondary"; }

GUI_LOG="$TMP_DIR/gui.log"
cleanup_gui() { cleanup 2>/dev/null || :; }
trap cleanup_gui EXIT

# ---------------------------------------------------------------------------
# Modo de contingência (sem a interface Tkinter): login e menu via zenity.
# Numeração oficial das tarefas (1 a 30), na mesma ordem dos blocos da interface:
#  1-6  COMPARAR / MOVER      7-11  CONSULTAR        12-16 EXCLUIR
# 17-21 ARQUIVOS / CLONAR    22-25  CRIAR            26-28 RENOMEAR
# 29-30 MUDAR pasta / LOGOFF
# ---------------------------------------------------------------------------
show_login() {
  local credentials code
  while :; do
    credentials=$(zenity --forms \
      --title="$APP_TITLE | Login" \
      --text="G I T   L O C A L\nGERENCIADOR DE REPOSITÓRIOS GITHUB\n\nCriar token PAT: https://github.com/settings/tokens\n\nEntre com suas credenciais. O token é usado somente nesta sessão e não será salvo em arquivo." \
      --add-entry="Usuário GitHub" \
      --add-password="Personal Access Token (PAT)" \
      --separator='|' --width=620 --height=300 2>/dev/null) || return 1
    IFS='|' read -r GITHUB_USER GITHUB_TOKEN <<< "$credentials"
    if [[ -z "$GITHUB_USER" || -z "$GITHUB_TOKEN" ]]; then
      zenity --error --title="$APP_TITLE | Login" --text="Informe o usuário e o token PAT." 2>/dev/null || :
      continue
    fi
    code=$(curl -sS -o "$TMP_DIR/gui-login.json" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "$API_URL/user" 2>/dev/null) || code=000
    if [[ "$code" == 200 ]] && jq -e --arg u "$GITHUB_USER" '(.login|ascii_downcase)==($u|ascii_downcase)' "$TMP_DIR/gui-login.json" >/dev/null 2>&1; then
      GITHUB_USER=$(jq -r '.login' "$TMP_DIR/gui-login.json")
      return 0
    fi
    GITHUB_TOKEN=""
    zenity --error --title="$APP_TITLE | Login recusado" --text="Não foi possível validar o login/token (HTTP ${code}). Confira o usuário, o PAT e as permissões." 2>/dev/null || :
  done
}
show_menu() {
  zenity --list --radiolist \
    --title="$APP_TITLE | Menu principal" \
    --text="Olá, ${GITHUB_USER}.\nSelecione uma tarefa e clique em OK. As operações são executadas pelas funções do script original." \
    --column="Selecionar" --column="Nº" --column="Categoria" --column="Tarefa" \
    --hide-column=1 --print-column=2 --separator='' \
    --width=1080 --height=760 --ok-label="Executar tarefa" --cancel-label="Sair" \
    FALSE 1 "COMPARAR / MOVER" "Comparar arquivo local/remoto" \
    FALSE 2 "COMPARAR / MOVER" "Mover arquivo da MAIN" \
    FALSE 3 "COMPARAR / MOVER" "Mover arquivo da BRANCH secundária" \
    FALSE 4 "COMPARAR / MOVER" "MOVER TODOS arquivos da BRANCH main para pasta" \
    FALSE 5 "COMPARAR / MOVER" "MOVER TODOS arquivos da BRANCH secundária para pasta" \
    FALSE 6 "COMPARAR / MOVER" "Enviar TODOS arquivos de qualquer pasta para..." \
    FALSE 7 CONSULTAR "Listar repositórios e subpastas MAIN" \
    FALSE 8 CONSULTAR "Pesquisar arquivo / branch / caminho" \
    FALSE 9 CONSULTAR "Listar arquivos locais" \
    FALSE 10 CONSULTAR "Listar arquivos do repositório MAIN" \
    FALSE 11 CONSULTAR "Listar arquivos da BRANCH secundária" \
    FALSE 12 EXCLUIR "Excluir REPOSITÓRIO" \
    FALSE 13 EXCLUIR "Deletar BRANCH secundária" \
    FALSE 14 EXCLUIR "Excluir pasta do REPOSITÓRIO" \
    FALSE 15 EXCLUIR "Excluir pasta da BRANCH secundária" \
    FALSE 16 EXCLUIR "Deletar arquivo remoto" \
    FALSE 17 "ENVIAR ARQUIVOS" "Baixar arquivo remoto" \
    FALSE 18 "ENVIAR ARQUIVOS" "Enviar arquivo local ao GitHub" \
    FALSE 19 "ENVIAR ARQUIVOS" "Clonar repositório de terceiros" \
    FALSE 20 "ENVIAR ARQUIVOS" "Enviar arquivo em anexo" \
    FALSE 21 "ENVIAR ARQUIVOS" "Enviar diversos anexos" \
    FALSE 22 CRIAR "Criar REPOSITÓRIO" \
    FALSE 23 CRIAR "Criar BRANCH secundária vazia" \
    FALSE 24 CRIAR "Criar PASTA no REPOSITÓRIO" \
    FALSE 25 CRIAR "Criar pasta na BRANCH secundária" \
    FALSE 26 RENOMEAR "Renomear repositório" \
    FALSE 27 RENOMEAR "Renomear BRANCH secundária" \
    FALSE 28 RENOMEAR "Renomear pasta da BRANCH" \
    FALSE 29 "MUDAR pasta / LOGOFF" "Mudar diretório local" \
    FALSE 30 "MUDAR pasta / LOGOFF" "Trocar usuário GitHub" 2>/dev/null
}
run_task() {
  local option="$1" fn="" rc=0
  GUI_LAST_PROMPT=""
  GUI_CANCELLED=0
  case "$option" in
    1) fn=compare_local_remote_file;;
    2) fn=move_main_repository_files;;
    3) fn=move_secondary_branch_files;;
    4) fn=move_all_repository_folder_files;;
    5) fn=move_all_main_branch_files;;
    6) fn=move_all_secondary_branch_files;;
    7) fn=list_repositories;;
    8) fn=search_file;;
    9) fn=list_local_files;;
    10) fn=list_main_repository_files;;
    11) fn=list_secondary_branch_files;;
    12) fn=delete_repository;;
    13) fn=delete_secondary_branch;;
    14) fn=delete_folder_main;;
    15) fn=delete_folder_secondary_branch;;
    16) fn=delete_remote_file;;
    17) fn=download_file;;
    18) fn=upload_file;;
    19) fn=clone_third_party_repository;;
    20|21) fn=upload_selected_attachments;;
    22) fn=create_repository_main;;
    23) fn=create_secondary_branch;;
    24) fn=create_folder_main;;
    25) fn=create_folder_secondary_branch;;
    26) fn=rename_repository;;
    27) fn=rename_secondary_branch;;
    28) fn=rename_folder_secondary_branch;;
    29) fn=change_current_directory;;
    30) logout_github; GITHUB_USER=""; GITHUB_TOKEN=""; return 2;;
    0) return 1;;
    *) zenity --error --title="$APP_TITLE" --text="Opção inválida." 2>/dev/null || :; return 0;;
  esac
  if [[ "${GUI_EMBEDDED:-0}" == 1 ]]; then
    if "$fn"; then rc=0; else rc=$?; fi
    builtin printf '\n============================================================\nDIRETÓRIO LOCAL CONFIGURADO: %s\n' "$(get_local_base_dir)"
    builtin printf '__GUI_DONE__%s\n' "$rc"
    return "$rc"
  fi
  : > "$GUI_LOG"
  if "$fn" >"$GUI_LOG" 2>&1; then rc=0; else rc=$?; fi
  printf '\n============================================================\nDIRETÓRIO LOCAL CONFIGURADO: %s\n' "$(get_local_base_dir)" >> "$GUI_LOG"
  if [[ ! -s "$GUI_LOG" ]]; then
    if [[ $rc -eq 0 ]]; then echo "Tarefa concluída." > "$GUI_LOG"; else echo "A tarefa terminou com código $rc." > "$GUI_LOG"; fi
  fi
  if [[ $rc -eq 0 ]]; then
    zenity --text-info --title="$APP_TITLE | Resultado" --filename="$GUI_LOG" --width=850 --height=600 --ok-label="Voltar ao menu" 2>/dev/null || :
  else
    zenity --text-info --title="$APP_TITLE | Resultado / aviso" --filename="$GUI_LOG" --width=850 --height=600 --ok-label="Voltar ao menu" 2>/dev/null || :
  fi
  return 0
}
main_gui() {
  local choice rc local_files
  if ! show_login; then exit 0; fi
  while :; do
    choice=$(show_menu) || break
    [[ -n "$choice" ]] || continue
    [[ "$choice" =~ ^([0-9]|[12][0-9]|30)$ ]] || { zenity --error --title="$APP_TITLE" --text="Informe um número entre 0 e 30." 2>/dev/null || :; continue; }
    if [[ "$choice" == 0 ]]; then break; fi
    if [[ "$choice" == 20 || "$choice" == 21 ]]; then
      local_files=""
      if [[ "$choice" == 20 ]]; then
        local_files=$(zenity --file-selection --title="Selecionar arquivo em anexo" --filename="$(get_local_base_dir)/" 2>/dev/null) || continue
        GITHUB_ATTACHMENTS_JSON=$(jq -n --arg f "$local_files" '[$f]')
      else
        local_files=$(zenity --file-selection --multiple --separator=$'\n' --title="Selecionar diversos anexos" --filename="$(get_local_base_dir)/" 2>/dev/null) || continue
        GITHUB_ATTACHMENTS_JSON=$(while IFS= read -r f; do [[ -n "$f" ]] && jq -Rn --arg f "$f" '$f'; done <<< "$local_files" | jq -s '.')
      fi
    fi
    rc=0
    run_task "$choice" || rc=$?
    unset GITHUB_ATTACHMENTS_JSON
    if [[ $rc -eq 2 ]]; then
      if ! show_login; then break; fi
    elif [[ $rc -eq 1 ]]; then
      break
    fi
  done
  GITHUB_TOKEN=""
  GITHUB_USER=""
  zenity --info --title="$APP_TITLE" --text="Sessão encerrada." 2>/dev/null || :
}
if [[ "${1:-}" == "--task" ]]; then
  GUI_EMBEDDED=1
  run_task "${2:-0}"
else
  main_gui
fi
GITHUB_MANAGER_APP_EOF_9A71C2
chmod 700 "$APP_TMP" || fail 'Não foi possível proteger o núcleo Bash temporário.'
mv -f -- "$APP_TMP" "$APP" || fail 'Não foi possível instalar atomicamente o núcleo Bash.'
GUI_TMP="$(mktemp "$BASE/.github-manager-gui.py.XXXXXXXX")" || fail 'Não foi possível preparar a interface Python temporária.'
cat > "$GUI_TMP" <<'GITHUB_MANAGER_GUI_PY_EOF_3B82D1'
#!/usr/bin/env python3
# Interface gráfica incorporada no instalador; execução e entradas na janela principal.
import tkinter as tk
from tkinter import ttk, filedialog
import os, subprocess, threading, urllib.request, json, queue, webbrowser, colorsys
from pathlib import Path

TITLE = "GitHub Manager — GIT LOCAL"
APP = Path.home() / ".local/share/github-manager/github-manager.sh"
BG = "#e9f1ff"
INK = "#172033"
M = 8  # margem lateral única: cabeçalho, blocos, rodapé e status ocupam a mesma largura.

# Licença aplicada ao programa (exibida no 8º bloco e no cabeçalho).
LICENSE_NAME = "Sem licença open-source declarada pelo autor"
LICENSE_DETAIL = ("Direitos autorais reservados ao autor (regime legal padrão na ausência de licença). "
                  "Uso, cópia, alteração ou redistribuição dependem de autorização do autor.")
THIRD_PARTY = ("Python/Tkinter (PSF), curl (licença curl), jq (MIT), Git (GPL-2.0), Zenity (LGPL-2.1+). "
               "Cada componente segue a sua licença original; a API do GitHub segue os Termos do GitHub.")

# Blocos em ordem decrescente de quantidade de menus (6,5,5,5,4,3,2); numeração contínua de 1 a 30.
TASKS = {
"COMPARAR / MOVER": ("#facc15", [(1,"Comparar arquivo local/remoto"),(2,"Mover arquivo da MAIN"),(3,"Mover arquivo da BRANCH"),(4,"MOVER TODOS arquivos da BRANCH main para pasta"),(5,"MOVER TODOS arquivos da BRANCH secundária para pasta"),(6,"Enviar TODOS arquivos de qualquer pasta para...")]),
"CONSULTAR": ("#0a0a0a", [(7,"Listar repositórios e pastas"),(8,"Pesquisar arquivo / caminho"),(9,"Listar arquivos locais"),(10,"Listar arquivos da MAIN"),(11,"Listar arquivos da BRANCH")]),
"EXCLUIR": ("#eab308", [(12,"Excluir REPOSITÓRIO"),(13,"Excluir BRANCH secundária"),(14,"Excluir pasta do REPOSITÓRIO"),(15,"Excluir pasta da BRANCH secundária"),(16,"Excluir arquivo remoto")]),
"ENVIAR ARQUIVOS": ("#171717", [(17,"Baixar arquivo remoto"),(18,"Enviar arquivo ao GitHub"),(19,"Clonar repositório de terceiros"),(20,"Enviar arquivo em anexo"),(21,"Enviar diversos anexos")]),
"CRIAR": ("#fde047", [(22,"Criar REPOSITÓRIO"),(23,"Criar BRANCH secundária"),(24,"Criar PASTA no REPOSITÓRIO"),(25,"Criar pasta na BRANCH")]),
"RENOMEAR": ("#0f0f0f", [(26,"Renomear repositório"),(27,"Renomear BRANCH secundária"),(28,"Renomear pasta da BRANCH")]),
"MUDAR pasta / LOGOFF": ("#ca8a04", [(29,"Mudar diretório local"),(30,"Trocar usuário GitHub")]),
}
assert sorted(n for _c, items in TASKS.values() for n, _l in items) == list(range(1, 31)), "Numeração dos menus deve ser 1..30"
assert [len(items) for _c, items in TASKS.values()] == sorted((len(items) for _c, items in TASKS.values()), reverse=True), "Blocos devem estar em ordem decrescente"

class RoundedButton(tk.Canvas):
  def __init__(self, master, text, command, bg="#ffffff", fg=INK, accent="#2563eb", height=28, **kwargs):
    kwargs.setdefault("width",150)
    super().__init__(master,height=height,highlightthickness=0,bd=0,bg=master.cget("bg"),cursor="hand2",**kwargs)
    self.text,self.command,self.fill,self.fg,self.accent=text,command,bg,fg,accent
    self.base_fill=bg; self.base_fg=fg; self.height_px=height; self.enabled=True; self.hovering=False
    self.bind("<Configure>",self.draw); self.bind("<Button-1>",self.click); self.bind("<Enter>",self.hover); self.bind("<Leave>",self.leave)
    self.draw()
  def rounded(self,x1,y1,x2,y2,r,**kw):
    pts=[x1+r,y1,x2-r,y1,x2,y1,x2,y1+r,x2,y2-r,x2,y2,x2-r,y2,x1+r,y2,x1,y2,x1,y2-r,x1,y1+r,x1,y1]
    return self.create_polygon(pts,smooth=True,splinesteps=18,**kw)
  def draw(self,event=None):
    self.delete("all"); w=max(self.winfo_width(),40); h=self.height_px
    self.rounded(2,2,w-2,h-2,9,fill=self.fill,outline=self.accent,width=1.5 if self.hovering else 1.1)
    self.create_text(w/2,h/2,text=self.text,fill=self.fg,font=("Sans",8,"bold"),width=max(40,w-12),justify="center")
  def click(self,event=None):
    if self.enabled and callable(self.command): self.command()
  def set_enabled(self,value):
    self.enabled=bool(value); self.hovering=False
    self.itemconfigure("all",state=("normal" if self.enabled else "disabled"))
    if not self.enabled:
      self.base_fill="#e2e8f0"; self.base_fg="#64748b"
    else:
      self.base_fill="#2563eb" if self.text=="ENTRAR" else "#ffffff"
      self.base_fg="white" if self.text=="ENTRAR" else ("#173b75" if self.text=="VOLTAR AOS MENUS" else INK)
    self.fill=self.base_fill; self.fg=self.base_fg; self.draw()
  def hover(self,event=None):
    if not self.enabled: return
    self.hovering=True
    try:
      rgb=tuple(int(self.base_fill[i:i+2],16) for i in (1,3,5))
      self.fill="#"+"".join(f"{round(c+(255-c)*0.24):02x}" for c in rgb)
    except Exception: self.fill="#dbeafe"
    self.draw()
  def leave(self,event=None):
    self.hovering=False; self.fill=self.base_fill; self.fg=self.base_fg; self.draw()

class App:
  def __init__(self,root):
    self.root=root; root.title(TITLE); root.configure(bg=BG)
    sw=root.winfo_screenwidth(); sh=root.winfo_screenheight()
    # Janela dimensionada pela resolução disponível, sem ultrapassar a área útil.
    width=min(sw,1600); height=min(max(560,sh-60),940); height=min(height,sh)
    x=max(0,(sw-width)//2); y=max(0,(sh-height)//2)
    root.geometry(f"{width}x{height}+{x}+{y}")
    root.minsize(min(980,sw),min(560,sh))
    self.user=""; self.token=""; self.busy=False; self.proc=None; self.input_queue=None; self.refresh_job=None
    self.style=ttk.Style(); self.style.configure("TEntry",padding=4)
    self.login_screen()
  def clear(self):
    if self.refresh_job:
      try: self.root.after_cancel(self.refresh_job)
      except Exception: pass
      self.refresh_job=None
    for w in self.root.winfo_children(): w.destroy()
    # Zera a grade da raiz para que cada tela redistribua a largura total da janela.
    self.root.grid_columnconfigure(0,weight=1)
    for r in range(6): self.root.grid_rowconfigure(r,weight=0,minsize=0)
  def set_login_status(self,text,color="#b91c1c"):
    if hasattr(self,"login_status") and self.login_status.winfo_exists(): self.login_status.config(text=text,fg=color)
  def login_screen(self):
    self.clear(); self.root.configure(bg="#071326"); outer=tk.Frame(self.root,bg="#071326",padx=12,pady=10); outer.pack(fill="both",expand=True)
    outer.grid_columnconfigure(0,weight=1); outer.grid_rowconfigure(0,weight=1); outer.grid_rowconfigure(2,weight=1)
    panel=tk.Frame(outer,bg="#101f3d",highlightbackground="#22d3ee",highlightthickness=2,padx=26,pady=18); panel.grid(row=1,column=0)
    tk.Label(panel,text="GIT LOCAL",font=("Sans",24,"bold"),bg="#101f3d",fg="#facc15",anchor="center").pack(fill="x",pady=(0,4))
    tk.Label(panel,text="GERENCIADOR DE REPOSITÓRIOS GITHUB",font=("Sans",9,"bold"),bg="#101f3d",fg="#a5d8ff").pack(pady=(0,12))
    form=tk.Frame(panel,bg="#101f3d"); form.pack()
    tk.Label(form,text="Usuário GitHub",bg="#101f3d",fg="#e2e8f0").grid(row=0,column=0,sticky="w",pady=5)
    self.user_var=tk.StringVar(); self.user_entry=ttk.Entry(form,textvariable=self.user_var,width=34); self.user_entry.grid(row=0,column=1,padx=(12,0),pady=5)
    tk.Label(form,text="Personal Access Token (PAT)",bg="#101f3d",fg="#e2e8f0").grid(row=1,column=0,sticky="w",pady=5)
    self.token_var=tk.StringVar(); self.token_entry=ttk.Entry(form,textvariable=self.token_var,show="•",width=34); self.token_entry.grid(row=1,column=1,padx=(12,0),pady=5)
    self.user_entry.bind("<Return>",lambda e:self.token_entry.focus_set())
    self.token_entry.bind("<Return>",lambda e:self.login())
    guide=tk.Frame(panel,bg="#142b50",highlightbackground="#38bdf8",highlightthickness=1,padx=12,pady=9)
    guide.pack(fill="x",pady=(8,6))
    tk.Label(guide,text="COMO OBTER SUA CHAVE PAT (PASSO A PASSO)",bg="#142b50",fg="#67e8f9",font=("Sans",9,"bold"),anchor="w").pack(fill="x",pady=(0,4))
    steps=(
      "1. Acesse github.com e entre na sua conta.",
      "2. Clique na foto do perfil (canto superior direito) > Settings.",
      "3. No menu lateral, abra Developer settings > Personal access tokens > Fine-grained tokens.",
      "4. Clique em Generate new token; informe um nome e uma validade.",
      "5. Em Resource owner, selecione sua conta. Em Repository access, escolha Only select repositories e marque os repositórios que o programa usará (ou All repositories, se realmente necessário).",
      "6. Em Repository permissions, configure Contents = Read and write e Metadata = Read-only. Para criar/excluir repositórios ou administrar configurações, habilite também Administration = Read and write, se a operação exigir.",
      "7. Clique em Generate token e copie o valor imediatamente. O GitHub não o exibirá novamente.",
      "8. Cole o PAT no campo acima e clique em ENTRAR. O token não é gravado pelo programa; fica somente na sessão atual.",
    )
    for step in steps:
      tk.Label(guide,text=step,bg="#142b50",fg="#e2e8f0",font=("Sans",8),justify="left",anchor="w",wraplength=650).pack(fill="x",anchor="w",pady=1)
    pat_url="https://github.com/settings/tokens"
    link=tk.Label(guide,text="CRIAR TOKEN PAT NO GITHUB:  "+pat_url,bg="#142b50",fg="#facc15",font=("Sans",8,"underline"),cursor="hand2",anchor="w")
    link.pack(fill="x",pady=(5,0)); link.bind("<Button-1>",lambda e: webbrowser.open(pat_url))
    tk.Label(panel,text="O PAT é uma credencial sensível. Nunca o compartilhe nem o envie em mensagens.",bg="#101f3d",fg="#fda4af",font=("Sans",8,"bold"),wraplength=560).pack(pady=5)
    RoundedButton(panel,"ENTRAR",self.login,bg="#2563eb",fg="white",accent="#2563eb",height=36,width=190).pack(pady=5)
    self.login_status=tk.Label(panel,text="",bg="#101f3d",fg="#fda4af",wraplength=460,justify="center"); self.login_status.pack(pady=(5,0))
    self.user_entry.focus_set()
  def login(self):
    user=self.user_var.get().strip(); token=self.token_var.get().strip()
    if not user or not token: self.set_login_status("Informe o usuário e o token PAT."); return
    self.set_login_status("Validando credenciais…","#e2e8f0"); self.root.update_idletasks()
    req=urllib.request.Request("https://api.github.com/user",headers={"Accept":"application/vnd.github+json","Authorization":"Bearer "+token,"X-GitHub-Api-Version":"2022-11-28"})
    try:
      with urllib.request.urlopen(req,timeout=20) as r: data=json.loads(r.read().decode())
      if data.get("login","").lower()!=user.lower(): raise ValueError("O usuário informado não corresponde ao usuário autenticado pelo token.")
    except Exception as e: self.set_login_status("Falha no login/token: "+str(e)); return
    self.user=data["login"]; self.token=token; self.menu_screen()
  def bind_row_hover(self,row,*widgets):
    def enter(event=None):
      row.configure(highlightthickness=2,highlightbackground="#facc15",highlightcolor="#facc15")
    def leave(event=None):
      row.configure(highlightthickness=0)
    for widget in (row,)+widgets:
      widget.bind("<Enter>",enter,add="+")
      widget.bind("<Leave>",leave,add="+")
  def make_card(self,parent,name,color,items):
    # Cada bloco tem preenchimento próprio; cabeçalho de altura fixa mantém as linhas alinhadas entre os 7 blocos.
    rgb=tuple(int(color[i:i+2],16)/255 for i in (1,3,5))
    _h,_s,v=colorsys.rgb_to_hsv(*rgb)
    # Amarelo/preto: texto escuro em fundos claros (amarelo) e texto claro em fundos escuros (preto).
    if v>0.55:
      number_color="#0a0a0a"; btn_fg="#0a0a0a"; title_fg="#facc15"
    else:
      number_color="#0a0a0a"; btn_fg="#facc15"; title_fg="#facc15"
    box=tk.Frame(parent,bg=color,highlightbackground="#facc15" if v<=0.55 else "#0a0a0a",highlightthickness=2,padx=4,pady=5)
    title=tk.Frame(box,bg=number_color,highlightbackground="#facc15",highlightthickness=1,height=44)
    title.pack(fill="x",pady=(0,5)); title.pack_propagate(False)
    tl=tk.Label(title,text=name,bg=number_color,fg=title_fg,font=("Sans",9,"bold"),padx=3,pady=2,anchor="center",justify="center",wraplength=100)
    tl.pack(fill="both",expand=True)
    for n,label in items:
      line=tk.Frame(box,bg=color,highlightthickness=0); line.pack(fill="x",pady=1)
      number=tk.Label(line,text=f"{n:02d}",bg=number_color,fg="#facc15",font=("Sans",8,"bold"),width=3,pady=3); number.pack(side="left",fill="y",padx=(0,3))
      button=RoundedButton(line,text=label,command=lambda x=n:self.dispatch_menu_task(x),bg=color,fg=btn_fg,accent="#0a0a0a" if v>0.55 else "#facc15",height=50,width=20); button.pack(side="left",fill="x",expand=True)
      self.bind_row_hover(line,number,button)
    box.bind("<Configure>",lambda e,t=tl:t.config(wraplength=max(60,e.width-24)))
    return box
  def current_local_directory(self):
    config_root=Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home()/".config")))
    config_file=config_root/"github-manager"/"current-directory"
    try:
      candidate=Path(config_file.read_text(encoding="utf-8").strip()).expanduser()
      if candidate.is_dir(): return str(candidate.resolve())
    except Exception:
      pass
    return str(Path.cwd())
  def make_info_card(self,parent):
    dark="#172033"
    box=tk.Frame(parent,bg="#e8eef7",highlightbackground="#64748b",highlightthickness=2,padx=6,pady=5)
    title=tk.Frame(box,bg=dark,highlightbackground="#ffffff",highlightthickness=1,height=44)
    title.pack(fill="x",pady=(0,5)); title.pack_propagate(False)
    tl=tk.Label(title,text="CENTRAL DE INFORMAÇÕES",bg=dark,fg="#ffffff",font=("Sans",9,"bold"),padx=3,pady=2,anchor="center",justify="center",wraplength=100)
    tl.pack(fill="both",expand=True)
    details=[
      ("FLUXO", "Escolha uma tarefa; perguntas e resultados aparecem nesta janela."),
      ("SEGURANÇA", "O PAT fica somente na sessão. Não o compartilhe."),
      ("DIRETÓRIO LOCAL ATUAL", self.current_local_directory()),
      ("LICENÇA APLICADA", LICENSE_NAME+". "+LICENSE_DETAIL),
      ("COMPONENTES DE TERCEIROS", THIRD_PARTY),
    ]
    wrap_labels=[tl]
    for heading,content in details:
      tk.Label(box,text=heading,bg="#e8eef7",fg="#173b75",font=("Sans",8,"bold"),anchor="w").pack(fill="x",pady=(4,0))
      value=tk.Label(box,text=content,bg="#e8eef7",fg="#24344d",font=("Sans",8),anchor="w",justify="left",wraplength=110)
      value.pack(fill="x",anchor="w"); wrap_labels.append(value)
      if heading=="DIRETÓRIO LOCAL ATUAL": self.directory_value=value
    box.bind("<Configure>",lambda e,ls=wrap_labels:[l.config(wraplength=max(60,e.width-24)) for l in ls])
    return box
  def refresh_local_directory(self):
    self.refresh_job=None
    if hasattr(self,"directory_value") and self.directory_value.winfo_exists():
      self.directory_value.config(text=self.current_local_directory())
      self.refresh_job=self.root.after(1500,self.refresh_local_directory)
  def choose_attachments(self,multiple):
    initial=self.current_local_directory()
    if multiple:
      selected=filedialog.askopenfilenames(title="Selecionar diversos anexos",initialdir=initial,parent=self.root)
    else:
      one=filedialog.askopenfilename(title="Selecionar arquivo em anexo",initialdir=initial,parent=self.root)
      selected=(one,) if one else ()
    if not selected: return
    paths=[str(Path(item).expanduser().resolve()) for item in selected]
    self.run_task(21 if multiple else 20,attachments=paths)
  def menu_screen(self):
    self.clear(); self.root.configure(bg=BG)
    self.root.grid_rowconfigure(1,weight=1)
    # Cabeçalho, blocos, rodapé e status usam a mesma margem lateral (M) e ocupam toda a largura.
    header=tk.Frame(self.root,bg="#071326",padx=9,pady=5,highlightbackground="#22d3ee",highlightthickness=2)
    header.grid(row=0,column=0,sticky="ew",padx=M,pady=(M,3))
    tk.Frame(header,bg="#22d3ee",height=2).pack(fill="x",pady=(0,3))
    tk.Label(header,text="✦  GIT LOCAL  ·  CENTRO DE COMANDO GITHUB  ✦",font=("Sans",17,"bold"),bg="#071326",fg="#facc15",anchor="center").pack(fill="x")
    tk.Label(header,text="Seu painel tático para repositórios, branches e arquivos — poder local, precisão remota.",font=("Sans",8,"bold"),bg="#071326",fg="#f8fafc",anchor="center").pack(fill="x",pady=(2,0))
    tk.Label(header,text="Stack: Linux  ·  Bash  ·  Python/Tkinter  ·  GitHub REST API",font=("Sans",8),bg="#071326",fg="#67e8f9",anchor="center").pack(fill="x")
    lic=tk.Label(header,text="LICENÇA: "+LICENSE_NAME+". "+LICENSE_DETAIL+"  |  Componentes de terceiros mantêm suas licenças originais.",font=("Sans",7,"bold"),bg="#071326",fg="#fda4af",anchor="center",wraplength=1100)
    lic.pack(fill="x",pady=(2,0))
    header.bind("<Configure>",lambda e,l=lic:l.config(wraplength=max(300,e.width-30)))
    tk.Label(header,text="Sessão: "+self.user,bg="#071326",fg="#cbd5e1",font=("Sans",7),anchor="e").pack(fill="x")
    tk.Frame(header,bg="#22d3ee",height=2).pack(fill="x",pady=(3,0))
    # Sete blocos de tarefas lado a lado, preenchendo e alinhando toda a largura da janela.
    body=tk.Frame(self.root,bg=BG); body.grid(row=1,column=0,sticky="nsew",padx=M,pady=3)
    body.grid_rowconfigure(0,weight=1)
    for c in range(7): body.grid_columnconfigure(c,weight=1,uniform="cols")
    def pad(c): return (0 if c==0 else 3, 0 if c==6 else 3)
    for index,(name,(color,items)) in enumerate(TASKS.items()):
      self.make_card(body,name,color,items).grid(row=0,column=index,sticky="nsew",padx=pad(index))

    self.refresh_job=self.root.after(1500,self.refresh_local_directory)
    # Rodapé justificado: mesma largura do cabeçalho e dos blocos.
    bottom=tk.Frame(self.root,bg="#e6ebf4",padx=10,pady=5,highlightbackground="#94a3b8",highlightthickness=1)
    bottom.grid(row=2,column=0,sticky="ew",padx=M,pady=(3,2))
    tk.Label(bottom,text="SELECIONAR MENU",bg="#e6ebf4",fg="#173b75",font=("Sans",9,"bold")).pack(side="left",padx=(2,8))
    tk.Label(bottom,text="Número 0–30:",bg="#e6ebf4",fg=INK,font=("Sans",9)).pack(side="left")
    self.number=tk.StringVar(); ent=ttk.Entry(bottom,textvariable=self.number,width=7,justify="center"); ent.pack(side="left",padx=5); ent.bind("<Return>",lambda e:self.run_selected())
    RoundedButton(bottom,"EXECUTAR",self.run_selected,bg="#2563eb",fg="white",accent="#2563eb",height=30,width=110).pack(side="left",padx=3)
    RoundedButton(bottom,"SAIR",self.close,bg="#ffffff",fg="#b91c1c",accent="#b91c1c",height=30,width=88).pack(side="right",padx=4)
    self.status=tk.Label(self.root,text="Pronto.  Atalhos: digite 1–30 + Enter  |  Esc = sair  |  clique nos blocos",anchor="w",bg=BG,fg="#46536a",padx=4,pady=2); self.status.grid(row=3,column=0,sticky="ew",padx=M,pady=(0,M-2))
    # Atalhos de teclado (não alteram a visualização)
    self.root.bind("<Escape>", lambda e: self.close())
    self.root.bind("<Control-q>", lambda e: self.close())
    ent.focus_set()
  def dispatch_menu_task(self,n):
    if n==20: self.choose_attachments(False)
    elif n==21: self.choose_attachments(True)
    else: self.run_task(n)
  def run_selected(self):
    s=self.number.get().strip()
    if not s.isdigit() or not (0<=int(s)<=30): self.status.config(text="Informe um número entre 0 e 30.",fg="#b91c1c"); return
    n=int(s)
    if n==0: self.close(); return
    self.number.set(""); self.dispatch_menu_task(n)
  def task_screen(self,n):
    self.clear(); self.root.configure(bg=BG); self.root.grid_rowconfigure(1,weight=1)
    top=tk.Frame(self.root,bg=BG,pady=5); top.grid(row=0,column=0,sticky="ew",padx=M)
    label=next((label for _,items in TASKS.values() for num,label in items if num==n),f"Tarefa {n}")
    tk.Label(top,text="GIT LOCAL",font=("Sans",17,"bold"),bg=BG,fg="#173b75",anchor="center").pack(fill="x")
    tk.Label(top,text=f"EXECUTANDO TAREFA {n}: {label}",font=("Sans",10,"bold"),bg=BG,fg="#334155",anchor="center").pack(fill="x",pady=(2,0))
    outframe=tk.Frame(self.root,bg=BG,pady=4); outframe.grid(row=1,column=0,sticky="nsew",padx=M); outframe.grid_rowconfigure(0,weight=1); outframe.grid_columnconfigure(0,weight=1)
    self.output=tk.Text(outframe,wrap="word",bg="white",fg=INK,relief="flat",padx=10,pady=8,font=("Monospace",9),state="disabled")
    scroll=ttk.Scrollbar(outframe,orient="vertical",command=self.output.yview); self.output.configure(yscrollcommand=scroll.set)
    self.output.grid(row=0,column=0,sticky="nsew"); scroll.grid(row=0,column=1,sticky="ns")
    promptbox=tk.Frame(self.root,bg="#e6ebf4",padx=10,pady=6,highlightbackground="#94a3b8",highlightthickness=1); promptbox.grid(row=2,column=0,sticky="ew",padx=M,pady=3)
    self.prompt_label=tk.Label(promptbox,text="Aguardando saída da tarefa…",bg="#e6ebf4",fg="#173b75",anchor="w",justify="left",wraplength=800)
    self.prompt_label.grid(row=0,column=0,columnspan=2,sticky="ew",pady=(0,3)); promptbox.columnconfigure(0,weight=1)
    promptbox.bind("<Configure>",lambda e:self.prompt_label.config(wraplength=max(200,e.width-30)))
    self.prompt_var=tk.StringVar(); self.prompt_entry=ttk.Entry(promptbox,textvariable=self.prompt_var); self.prompt_entry.grid(row=1,column=0,sticky="ew",padx=(0,6)); self.prompt_entry.bind("<Return>",lambda e:self.submit_input())
    self.send_button=RoundedButton(promptbox,"ENVIAR",self.submit_input,bg="#2563eb",fg="white",accent="#2563eb",height=31,width=100); self.send_button.grid(row=1,column=1)
    self.prompt_entry.configure(state="disabled"); self.send_button.set_enabled(False)
    bottom=tk.Frame(self.root,bg=BG,pady=3); bottom.grid(row=3,column=0,sticky="ew",padx=M,pady=(0,M-2))
    self.back_button=RoundedButton(bottom,"VOLTAR AOS MENUS",self.menu_screen,bg="#ffffff",fg="#173b75",accent="#2563eb",height=31,width=170); self.back_button.pack(side="left"); self.back_button.set_enabled(False)
    self.task_status=tk.Label(bottom,text="A tarefa está em execução.",bg=BG,fg="#46536a",anchor="e"); self.task_status.pack(side="right",fill="x",expand=True)
    self.root.bind("<Escape>", lambda e: self._escape_from_task())
    self.append_output(f"Tarefa {n} iniciada. A saída e as perguntas aparecerão nesta janela.\n")
    self.append_output("Dica: após concluir, pressione Esc ou clique em VOLTAR AOS MENUS.\n")
  def _escape_from_task(self):
    # Só volta ao menu se a tarefa já terminou (botão habilitado)
    if hasattr(self,"back_button") and self.back_button.enabled:
      self.menu_screen()
  def append_output(self,text):
    if not hasattr(self,"output") or not self.output.winfo_exists(): return
    self.output.configure(state="normal"); self.output.insert("end",text); self.output.see("end"); self.output.configure(state="disabled")
  def show_inline_prompt(self,prompt):
    if not self.root.winfo_exists(): return
    self.prompt_label.config(text=prompt,fg="#173b75")
    self.prompt_entry.configure(state="normal"); self.send_button.set_enabled(True)
    self.prompt_entry.focus_set()
  def submit_input(self):
    if self.input_queue is None: return
    value=self.prompt_var.get(); self.prompt_var.set("")
    self.prompt_entry.configure(state="disabled"); self.send_button.set_enabled(False)
    self.prompt_label.config(text="Resposta enviada.",fg="#0f766e")
    self.append_output("\n> "+value+"\n")
    self.input_queue.put(value)
  def run_task(self,n,attachments=None):
    if self.busy:
      if hasattr(self,"status") and self.status.winfo_exists():
        self.status.config(text="Aguarde a tarefa atual terminar.",fg="#b91c1c")
      return
    if n not in range(1,31):
      if hasattr(self,"status") and self.status.winfo_exists():
        self.status.config(text="Opção inválida.",fg="#b91c1c")
      return
    if n==30:
      self.user=""; self.token=""; self.login_screen(); return
    if n in (20,21) and not attachments: return
    self.busy=True; self.input_queue=queue.Queue(); self.task_screen(n)
    env=os.environ.copy(); env["GITHUB_USER"]=self.user; env["GITHUB_TOKEN"]=self.token; env["PYTHONUNBUFFERED"]="1"
    if attachments is not None: env["GITHUB_ATTACHMENTS_JSON"]=json.dumps(attachments,ensure_ascii=False)
    def worker():
      try:
        proc=subprocess.Popen(["/usr/bin/env","bash",str(APP),"--task",str(n)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
        self.proc=proc
        for line in proc.stdout:
          if line.startswith("__GUI_PROMPT__"):
            prompt=line[len("__GUI_PROMPT__"):].rstrip("\r\n")
            self.root.after(0,self.show_inline_prompt,prompt)
            try: value=self.input_queue.get()
            except Exception: value=""
            try: proc.stdin.write(value+"\n"); proc.stdin.flush()
            except Exception: break
          elif line.startswith("__GUI_DONE__"):
            continue
          else:
            self.root.after(0,self.append_output,line)
        rc=proc.wait()
        self.root.after(0,self.task_finished,n,rc,None)
      except Exception as e:
        self.root.after(0,self.task_finished,n,1,str(e))
    threading.Thread(target=worker,daemon=True).start()
  def task_finished(self,n,rc,error):
    self.busy=False; self.proc=None
    if error: self.append_output("\nERRO: "+error+"\n")
    self.append_output(f"\nTarefa finalizada. Código de saída: {rc}.\n")
    self.prompt_label.config(text="Tarefa concluída. Nenhuma janela extra foi aberta.",fg="#0f766e" if rc==0 else "#b91c1c")
    self.prompt_entry.configure(state="disabled"); self.send_button.set_enabled(False)
    self.back_button.set_enabled(True); self.task_status.config(text="Concluída" if rc==0 else "Concluída com avisos")
  def close(self):
    self.token=""
    if self.proc and self.proc.poll() is None:
      try: self.proc.terminate()
      except Exception: pass
    self.root.destroy()

root=tk.Tk(); app=App(root); root.protocol("WM_DELETE_WINDOW",app.close); root.mainloop()
GITHUB_MANAGER_GUI_PY_EOF_3B82D1
chmod 700 "$GUI_TMP" || fail 'Não foi possível proteger a interface Python temporária.'
mv -f -- "$GUI_TMP" "$GUI" || fail 'Não foi possível instalar atomicamente a interface Python.'
chmod 700 "$APP" "$GUI"
bash -n "$APP" || { printf 'Erro de sintaxe no núcleo Bash.\n' >&2; exit 1; }
python3 -m py_compile "$GUI" || { printf 'Erro de sintaxe na interface gráfica.\n' >&2; exit 1; }
DESKTOP_ENTRY_TMP="$(mktemp "$DESKTOP_DIR/.GitHub-Manager.desktop.XXXXXXXX")" || fail 'Não foi possível preparar o atalho da Área de Trabalho.'
cat > "$DESKTOP_ENTRY_TMP" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=GitHub Manager — GIT LOCAL
Comment=Gerenciador gráfico de repositórios GitHub
Exec=python3 "$GUI"
Icon=applications-development
Terminal=false
Categories=Development;Network;
StartupNotify=true
EOF
chmod 755 "$DESKTOP_ENTRY_TMP" || fail 'Não foi possível proteger o atalho temporário.'
mv -f -- "$DESKTOP_ENTRY_TMP" "$DESKTOP_ENTRY" || fail 'Não foi possível instalar atomicamente o atalho da Área de Trabalho.'
chmod 755 "$DESKTOP_ENTRY"
[[ ! -L "$APP_ENTRY" ]] || fail 'O atalho do menu tornou-se um link simbólico; cópia bloqueada.'
APP_ENTRY_TMP="$(mktemp "$HOME/.local/share/applications/.GitHub-Manager.desktop.XXXXXXXX")" || fail 'Não foi possível preparar o atalho do menu.'
if ! cp -- "$DESKTOP_ENTRY" "$APP_ENTRY_TMP" || ! chmod 755 "$APP_ENTRY_TMP" || ! mv -f -- "$APP_ENTRY_TMP" "$APP_ENTRY"; then
  rm -f -- "$APP_ENTRY_TMP"
  fail 'Falha ao instalar atomicamente o atalho do menu.'
fi
command -v gio >/dev/null 2>&1 && gio set "$DESKTOP_ENTRY" metadata::trusted true 2>/dev/null || :
say 'ETAPA 4/4 — Validando os arquivos criados e finalizando.'
bash -n "$APP" || fail 'O núcleo Bash criado falhou na validação final.'
python3 -m py_compile "$GUI" || fail 'A interface Python criada falhou na validação final.'
trap - EXIT
printf '\nInstalação concluída.\nAtalho: %s\nNúcleo: %s\nInterface: %s\nBackup: %s\nRollback: %s/rollback.sh\nDê dois cliques no atalho da Área de Trabalho.\n' "$DESKTOP_ENTRY" "$APP" "$GUI" "$BACKUP" "$BACKUP"
