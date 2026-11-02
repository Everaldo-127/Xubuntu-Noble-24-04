#!/usr/bin/env bash
umask 077
PROGRAM_NAME="GitHub Manager"
API_URL="https://api.github.com"
API_VERSION="2022-11-28"
GITHUB_USER=""
GITHUB_TOKEN=""
SSH_KEY=""
TMP_DIR="${TMPDIR:-/tmp}/github-manager-$$"
mkdir -p "$TMP_DIR" || exit 1
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
pause() {
  printf '\nPressione ENTER para continuar...'
  IFS= read -r _
}
show_banner() {
  if [ -t 1 ] && [ -n "${TERM:-}" ] && command -v clear >/dev/null 2>&1; then
    clear 2>/dev/null || :
  fi
  printf '%s\n' \
    '╔══════════════════════════════════════════════════════════════════════╗' \
    '║                                                                      ║' \
    '║                 ██████╗ ██╗████████╗██╗  ██╗                         ║' \
    '║                ██╔════╝ ██║╚══██╔══╝██║  ██║                         ║' \
    '║                ██║  ███╗██║   ██║   ███████║                         ║' \
    '║                ██║   ██║██║   ██║   ██╔══██║                         ║' \
    '║                ╚██████╔╝██║   ██║   ██║  ██║                         ║' \
    '║                 ╚═════╝ ╚═╝   ╚═╝   ╚═╝  ╚═╝                         ║' \
    '║                                                                      ║' \
    '║                         GIT LOCAL                                    ║' \
    '║             Gerenciador de repositórios GitHub                       ║' \
    '╠══════════════════════════════════════════════════════════════════════╣' \
    '║  Repositórios, branches, pastas e arquivos pelo terminal.            ║' \
    '║  Token solicitado durante a execução e não exibido.                  ║' \
    '╚══════════════════════════════════════════════════════════════════════╝' \
    ''
}
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

  output_dir="$(dirname "$output")"
  if ! mkdir -p "$TMP_DIR" "$output_dir"; then
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
login_github() {
  local login token key response
  printf '\n============================================================\n'
  printf 'COMO GERAR SEU TOKEN PAT NO GITHUB\n'
  printf '%s\n' '1. Abra o link oficial: https://github.com/settings/tokens/new'
  printf '%s\n' '2. Entre no GitHub, se solicitado, e dê um nome ao token.'
  printf '%s\n' '3. Defina uma validade e selecione as permissões necessárias.'
  printf '%s\n' '   Para repositórios privados, habilite acesso aos repositórios'
  printf '%s\n' '   e permissões de leitura/escrita exigidas pelas operações usadas.'
  printf '%s\n' '4. Gere o token (Generate token) e copie-o imediatamente.'
  printf '%s\n' '5. Cole o token no campo PAT abaixo; ele não será exibido.'
  printf '%s\n' 'ATENÇÃO: nunca compartilhe seu PAT. O link pode ser aberto no navegador.'
  printf '%s\n' '============================================================'
  printf '\nLOGIN DO GITHUB: ' 
  IFS= read -r login
  if [ -z "$login" ]; then
    printf 'Login inválido.\n'
    return 1
  fi
  printf 'PERSONAL ACCESS TOKEN (PAT): '
  IFS= read -r -s token
  printf '\n'
  if [ -z "$token" ]; then
    printf 'Token não informado.\n'
    return 1
  fi
  GITHUB_USER="$login"
  GITHUB_TOKEN="$token"
  if ! api GET "/user" "" "$TMP_DIR/user.json"; then
    GITHUB_USER=""
    GITHUB_TOKEN=""
    return 1
  fi
  response=$(jq -r '.login // empty' "$TMP_DIR/user.json")
  if [ -z "$response" ]; then
    printf 'Não foi possível validar o usuário.\n'
    GITHUB_USER=""
    GITHUB_TOKEN=""
    return 1
  fi
  GITHUB_USER="$response"
  printf '\nLogin confirmado: %s\n' "$GITHUB_USER"
  printf '\nCaminho da chave SSH privada (ENTER para ignorar): '
  IFS= read -r key
  if [ -n "$key" ]; then
    if [ -f "$key" ]; then
      SSH_KEY="$key"
      if command -v ssh-add >/dev/null 2>&1; then
        ssh-add "$SSH_KEY" 2>/dev/null ||
          printf 'Aviso: não foi possível adicionar a chave ao ssh-agent.\n'
      fi
    else
      printf 'Arquivo de chave SSH não encontrado. Chave não configurada.\n'
    fi
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
  IFS= read -r name
  valid_name "$name" || {
    printf 'Nome inválido.\n'
    return 1
  }
  printf 'Descrição (opcional): '
  IFS= read -r description
  printf 'Repositório privado? (s/n): '
  IFS= read -r visibility
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
  IFS= read -r name
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
  local file remote_path encoded_repo encoded_path sha http_code answer
  ensure_login || return 1
  command -v base64 >/dev/null 2>&1 || { printf 'Erro: base64 não está disponível.\n'; return 1; }
  printf '\n=== ENVIAR ARQUIVO LOCAL AO GITHUB ===\n'
  printf 'Diretório local corrente: %s\n' "$PWD"
  select_repository || return 1
  printf 'Nome do arquivo local: '
  IFS= read -r file
  case "$file" in ""|"."|".."|*/*|*\\*) printf 'Erro: informe somente o nome do arquivo, sem caminhos.\n'; return 1 ;; esac
  [ -f "$PWD/$file" ] || { printf 'Erro: arquivo não encontrado: %s/%s\n' "$PWD" "$file"; return 1; }
  [ -r "$PWD/$file" ] || { printf 'Erro: o arquivo não possui permissão de leitura.\n'; return 1; }
  remote_path="$file"
  encoded_repo=$(urlencode "$SELECTED_REPO") || return 1
  encoded_path=$(urlencode_path "$remote_path") || return 1
  if ! base64 < "$PWD/$file" | tr -d '\r\n' > "$TMP_DIR/upload-content.b64"; then
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
    IFS= read -r answer
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
  local branch path output encoded_path filename repo_encoded
  select_repository || return 1
  printf 'Branch: '
  IFS= read -r branch
  [ -n "$branch" ] || branch="$DEFAULT_BRANCH"
  printf 'Caminho do arquivo remoto: '
  IFS= read -r path
  [ -n "$path" ] || {
    printf 'Caminho inválido.\n'
    return 1
  }
  filename="${path##*/}"
  [ -n "$filename" ] || {
    printf 'O caminho informado não contém um nome de arquivo válido.\n'
    return 1
  }
  output="$PWD/$filename"
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
  if ! jq -r '.content // empty' "$TMP_DIR/content.json" |
    tr -d '\n' | base64 -d > "$output"; then
    rm -f "$output"
    printf 'Falha ao gravar o arquivo local.\n'
    return 1
  fi
  printf '\nArquivo copiado para: %s\n' "$output"
}
delete_remote_file() {
  local branch path message sha payload answer
  select_repository || return 1
  printf 'Branch: '
  IFS= read -r branch
  [ -n "$branch" ] || branch="$DEFAULT_BRANCH"
  printf 'Caminho do arquivo remoto: '
  IFS= read -r path
  [ -n "$path" ] || {
    printf 'Caminho inválido.\n'
    return 1
  }
  local encoded_path repo_encoded
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
  IFS= read -r message
  [ -n "$message" ] || message="Exclusão via GitHub Manager"
  printf 'Confirma a exclusão de %s? (s/n): ' "$path"
  IFS= read -r answer
  case "$answer" in
    s|S|sim|SIM) ;;
    *) printf 'Operação cancelada.\n'; return 0 ;;
  esac
  payload=$(jq -n \
    --arg message "$message" \
    --arg sha "$sha" \
    --arg branch "$branch" \
    '{message:$message,sha:$sha,branch:$branch}')
  encoded_path=$(urlencode_path "$path") || return 1
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
  IFS= read -r folder
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
  IFS= read -r folder
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
  IFS= read -r confirm
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
}
create_secondary_branch() {
  local branch_name repo_encoded payload base_commit_sha base_tree_sha
  local commit_sha ref_status path encoded_path file_sha delete_payload delete_status
  ensure_login || return 1
  select_repository || return 1
  printf 'Nome da BRANCH secundária vazia: '
  IFS= read -r branch_name
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
  IFS= read -r branch_name
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
  IFS= read -r confirm
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
    204) printf 'BRANCH secundária "%s" deletada com sucesso.\n' "$branch_name" ;;
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
  IFS= read -r old_branch
  [ -n "$old_branch" ] || {
    printf 'Nome de branch inválido.\n'
    return 1
  }
  if [ "$old_branch" = "$DEFAULT_BRANCH" ]; then
    printf 'Operação bloqueada: não é permitido renomear a BRANCH PRINCIPAL.\n'
    return 1
  fi
  printf 'Novo nome da BRANCH secundária: '
  IFS= read -r new_branch
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
  IFS= read -r confirm
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
  IFS= read -r branch_name
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
  IFS= read -r folder
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
  IFS= read -r branch_name
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
  IFS= read -r folder
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
  IFS= read -r confirm
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
  IFS= read -r branch_name
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
  IFS= read -r old_folder
  old_folder=$(printf '%s' "$old_folder" | sed 's#^/*##;s#/*$##')
  validate_remote_folder "$old_folder" || {
    printf 'Caminho atual inválido. Exemplo: docs/guias\n'
    return 1
  }
  printf 'Novo caminho da pasta: '
  IFS= read -r new_folder
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
  IFS= read -r confirm
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
  local remote_date remote_sha http_code temp_remote
  ensure_login || return 1
  printf '\n=== COMPARAR ARQUIVO LOCAL COM REMOTO NO GITHUB ===\n'
  printf 'Diretório local corrente: %s\n' "$PWD"
  printf 'Nome do arquivo local: '
  IFS= read -r file
  case "$file" in
    ""|"."|".."|*/*|*\\*)
      printf 'Erro: informe somente o nome do arquivo, sem caminhos.\n'
      return 1
      ;;
  esac
  local_path="$PWD/$file"
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
    local diff_status=$?
    if [ "$diff_status" -gt 1 ]; then
      printf 'Não foi possível gerar a comparação textual; o arquivo pode ser binário.\n'
      return 1
    fi
  fi
  return 0
}
list_local_files() {
  printf '\nDiretório local: %s\n' "$PWD"
  find "$PWD" -maxdepth 1 -type f -print | sort
}
change_current_directory() {
  local requested_dir
  printf 'Diretório atual: %s\nNovo diretório: ' "$PWD"
  IFS= read -r requested_dir
  [ -n "$requested_dir" ] || { printf 'Diretório não informado.\n'; return 1; }
  case "$requested_dir" in '~') requested_dir="$HOME" ;; '~/'*) requested_dir="$HOME/${requested_dir#\~/}" ;; esac
  [ -d "$requested_dir" ] || { printf 'Diretório não encontrado: %s\n' "$requested_dir"; return 1; }
  cd -- "$requested_dir" || return 1
  printf 'Diretório corrente alterado para: %s\n' "$PWD"
}
search_file() {
  local page count repo default_branch branch path search_term
  ensure_login || return 1
  printf 'Nome ou trecho do nome do arquivo: '
  IFS= read -r search_term
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
  local url destination
  command -v git >/dev/null 2>&1 || {
    printf 'Git não está instalado.\n'
    return 1
  }
  printf 'URL HTTPS ou SSH do repositório: '
  IFS= read -r url
  [ -n "$url" ] || {
    printf 'URL inválida.\n'
    return 1
  }
  printf 'Diretório de destino (ENTER para usar o padrão): '
  IFS= read -r destination
  if [ -n "$destination" ]; then
    git clone "$url" "$destination"
  else
    git clone "$url"
  fi
}
delete_repository() {
  local name answer
  ensure_login || return 1
  printf 'Nome do repositório a excluir: '
  IFS= read -r name
  valid_name "$name" || {
    printf 'Nome inválido.\n'
    return 1
  }
  printf 'ATENÇÃO: excluir permanentemente %s/%s? (s/n): ' "$GITHUB_USER" "$name"
  IFS= read -r answer
  case "$answer" in
    s|S|sim|SIM) ;;
    *) printf 'Operação cancelada.\n'; return 0 ;;
  esac
  if api DELETE "/repos/$GITHUB_USER/$(urlencode "$name")"; then
    printf 'Repositório excluído.\n'
  fi
}
rename_repository() {
  local old_name new_name payload
  ensure_login || return 1
  printf 'Nome atual do repositório: '
  IFS= read -r old_name
  valid_name "$old_name" || {
    printf 'Nome inválido.\n'
    return 1
  }
  printf 'Novo nome do repositório: '
  IFS= read -r new_name
  valid_name "$new_name" || {
    printf 'Novo nome inválido.\n'
    return 1
  }
  payload=$(jq -n --arg name "$new_name" '{name:$name}')
  if api PATCH "/repos/$GITHUB_USER/$(urlencode "$old_name")" "$payload"; then
    printf 'Repositório renomeado para: %s\n' "$new_name"
  fi
}
list_repository_files_to_destination() {
  local mode="$1" repo branch folder destination repo_encoded branch_encoded folder_prefix
  local remote_path relative_path output_dir filename encoded_path download_url answer
  local total downloaded
  ensure_login || return 1
  if [ "$mode" = "main" ]; then
    printf '\n=== LISTAR ARQUIVOS DO REPOSITÓRIO MAIN ===\n'
  else
    printf '\n=== LISTAR ARQUIVOS DA BRANCH SECUNDÁRIA ===\n'
  fi
  printf 'Nome do repositório: '
  IFS= read -r repo
  valid_name "$repo" || { printf 'Nome de repositório inválido.\n'; return 1; }
  repo_encoded=$(urlencode "$repo") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded" "" "$TMP_DIR/list-files-repo.json"; then
    return 1
  fi
  DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$TMP_DIR/list-files-repo.json")
  if [ "$mode" = "main" ]; then
    printf 'Branch (ENTER para usar a MAIN: %s): ' "$DEFAULT_BRANCH"
    IFS= read -r branch
    [ -n "$branch" ] || branch="$DEFAULT_BRANCH"
  else
    printf 'Branch secundária (ENTER para listar as disponíveis): '
    IFS= read -r branch
    if [ -z "$branch" ]; then
      if ! api GET "/repos/$GITHUB_USER/$repo_encoded/branches?per_page=100" "" "$TMP_DIR/list-files-branches.json"; then
        return 1
      fi
      printf '\nBranches secundárias disponíveis:\n'
      jq -r --arg main "$DEFAULT_BRANCH" '.[] | select(.name != $main) | .name' "$TMP_DIR/list-files-branches.json" | nl -ba
      printf 'Digite o nome exato da branch secundária: '
      IFS= read -r branch
    fi
    [ -n "$branch" ] || { printf 'Nenhuma branch informada. Operação cancelada.\n'; return 1; }
    [ "$branch" != "$DEFAULT_BRANCH" ] || { printf 'A branch informada é a MAIN principal, não uma branch secundária.\n'; return 1; }
  fi
  printf 'Pasta remota (ENTER para a raiz do repositório): '
  IFS= read -r folder
  folder=${folder#/}
  folder=${folder%/}
  case "$folder" in *'..'*|*\\*) printf 'Caminho de pasta inválido.\n'; return 1 ;; esac
  printf 'Diretório local de destino (ENTER para %s): ' "$PWD"
  IFS= read -r destination
  [ -n "$destination" ] || destination="$PWD"
  case "$destination" in '~') destination="$HOME" ;; '~/'*) destination="$HOME/${destination#\~/}" ;; esac
  if [ ! -d "$destination" ]; then
    printf 'O destino não existe: %s\n' "$destination"
    printf 'Criar esse diretório? (s/n): '
    IFS= read -r answer
    case "$answer" in s|S|sim|SIM) mkdir -p -- "$destination" || { printf 'Não foi possível criar o destino.\n'; return 1; } ;; *) printf 'Operação cancelada.\n'; return 1 ;; esac
  fi
  [ -w "$destination" ] || { printf 'Sem permissão de escrita no destino: %s\n' "$destination"; return 1; }
  branch_encoded=$(urlencode "$branch") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/git/trees/$branch_encoded?recursive=1" "" "$TMP_DIR/list-files-tree.json"; then
    return 1
  fi
  if [ "$(jq -r '.truncated // false' "$TMP_DIR/list-files-tree.json")" = "true" ]; then
    printf 'AVISO: o GitHub informou que a árvore foi truncada; a lista pode estar incompleta.\n'
  fi
  : > "$TMP_DIR/list-files-paths.txt"
  if [ -n "$folder" ]; then
    folder_prefix="$folder/"
    jq -r --arg prefix "$folder_prefix" '.tree[]? | select(.type == "blob") | select(.path | startswith($prefix)) | .path' \
      "$TMP_DIR/list-files-tree.json" > "$TMP_DIR/list-files-paths.txt"
  else
    jq -r '.tree[]? | select(.type == "blob") | .path' \
      "$TMP_DIR/list-files-tree.json" > "$TMP_DIR/list-files-paths.txt"
  fi
  total=$(wc -l < "$TMP_DIR/list-files-paths.txt" | tr -d ' ')
  if [ "$total" -eq 0 ]; then
    printf 'Nenhum arquivo encontrado na pasta remota informada.\n'
    return 0
  fi
  printf '\nArquivos encontrados (%s):\n' "$total"
  cat "$TMP_DIR/list-files-paths.txt"
  printf '\nOs arquivos serão copiados para: %s\n' "$destination"
  printf 'Preservar nomes e subpastas relativas; continuar? (s/n): '
  IFS= read -r answer
  case "$answer" in s|S|sim|SIM) ;; *) printf 'Operação cancelada.\n'; return 0 ;; esac
  downloaded=0
  while IFS= read -r remote_path; do
    [ -n "$remote_path" ] || continue
    if [ -n "$folder" ]; then
      relative_path="${remote_path#"$folder_prefix"}"
    else
      relative_path="$remote_path"
    fi
    [ -n "$relative_path" ] || continue
    output_dir="$destination/${relative_path%/*}"
    if [ "$output_dir" = "$destination/$relative_path" ]; then
      output_dir="$destination"
    fi
    mkdir -p -- "$output_dir" || { printf 'Falha ao criar pasta local para: %s\n' "$remote_path"; continue; }
    filename="${remote_path##*/}"
    if [ -e "$output_dir/$filename" ]; then
      printf 'Já existe: %s/%s — substituir? (s/n): ' "$output_dir" "$filename"
      IFS= read -r answer
      case "$answer" in s|S|sim|SIM) ;; *) printf 'Ignorado: %s\n' "$remote_path"; continue ;; esac
    fi
    encoded_path=$(urlencode_path "$remote_path") || continue
    if ! api GET "/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path?ref=$branch_encoded" "" "$TMP_DIR/list-files-content.json"; then
      printf 'Falha ao obter: %s\n' "$remote_path"
      continue
    fi
    if [ "$(jq -r '.type // empty' "$TMP_DIR/list-files-content.json")" != "file" ]; then
      printf 'Ignorado (não é arquivo): %s\n' "$remote_path"
      continue
    fi
    if jq -e '.content and (.encoding == "base64")' "$TMP_DIR/list-files-content.json" >/dev/null 2>&1; then
      if ! jq -r '.content' "$TMP_DIR/list-files-content.json" | tr -d '\n' | base64 -d > "$output_dir/$filename"; then
        rm -f -- "$output_dir/$filename"
        printf 'Falha ao gravar: %s\n' "$remote_path"
        continue
      fi
    else
      download_url=$(jq -r '.download_url // empty' "$TMP_DIR/list-files-content.json")
      if [ -z "$download_url" ] || ! curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H "X-GitHub-Api-Version: $API_VERSION" "$download_url" -o "$output_dir/$filename"; then
        rm -f -- "$output_dir/$filename"
        printf 'Falha ao baixar arquivo grande: %s\n' "$remote_path"
        continue
      fi
    fi
    downloaded=$((downloaded + 1))
    printf 'Copiado: %s -> %s/%s\n' "$remote_path" "$output_dir" "$filename"
  done < "$TMP_DIR/list-files-paths.txt"
  printf '\nConcluído: %s de %s arquivo(s) copiado(s).\n' "$downloaded" "$total"
}
list_main_repository_files() {
  list_repository_files_to_destination "main"
}
list_secondary_branch_files() {
  list_repository_files_to_destination "secondary"
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
  IFS= read -r repo
  valid_name "$repo" || { printf 'Nome de repositório inválido.\n'; return 1; }
  repo_encoded=$(urlencode "$repo") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded" "" "$TMP_DIR/move-repo.json"; then return 1; fi
  DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$TMP_DIR/move-repo.json")
  if [ "$mode" = "main" ]; then
    branch="$DEFAULT_BRANCH"
    printf 'Usando MAIN: %s\n' "$branch"
  else
    printf 'Nome da BRANCH secundária: '
    IFS= read -r branch
    [ -n "$branch" ] || { printf 'Informe uma BRANCH secundária.\n'; return 1; }
    [ "$branch" != "$DEFAULT_BRANCH" ] || { printf 'A branch informada é a MAIN, não uma branch secundária.\n'; return 1; }
    if ! api GET "/repos/$GITHUB_USER/$repo_encoded/branches/$(urlencode "$branch")" "" "$TMP_DIR/move-branch.json"; then return 1; fi
  fi
  SELECTED_REPO="$repo"
  SELECTED_BRANCH="$branch"
}

list_remote_folder_files() {
  local mode="$1" folder repo_encoded total
  ensure_login || return 1
  if [ "$mode" = "main" ]; then printf '\n=== ARQUIVOS DA MAIN ===\n'; else printf '\n=== ARQUIVOS DA BRANCH SECUNDÁRIA ===\n'; fi
  choose_repository_branch "$mode" || return 1
  printf 'Caminho da pasta (ENTER para RAIZ): '
  IFS= read -r folder
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
  local requested_file matched_path
  ensure_login || return 1
  if [ "$mode" = "main" ]; then printf '\n=== MOVER ARQUIVO NA MAIN ===\n'; else printf '\n=== MOVER ARQUIVO NA BRANCH SECUNDÁRIA ===\n'; fi
  choose_repository_branch "$mode" || return 1
  printf 'Caminho da pasta de ORIGEM (ENTER para RAIZ): '
  IFS= read -r source_folder
  source_folder=${source_folder#/}; source_folder=${source_folder%/}
  if [ -n "$source_folder" ]; then validate_remote_folder "$source_folder" || { printf 'Caminho de origem inválido.\n'; return 1; }; fi
  remote_file_paths "$SELECTED_REPO" "$SELECTED_BRANCH" "$source_folder" || return 1
  if [ ! -s "$TMP_DIR/remote-files-paths.txt" ]; then printf 'Nenhum arquivo encontrado na origem.\n'; return 0; fi
  printf '\nArquivos disponíveis na origem:\n'
  cat "$TMP_DIR/remote-files-paths.txt"
  printf '\nInforme o NOME do arquivo a mover (com extensão, sem caminho): '
  IFS= read -r requested_file
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
  IFS= read -r destination_folder
  destination_folder=${destination_folder#/}; destination_folder=${destination_folder%/}
  if [ -n "$destination_folder" ]; then validate_remote_folder "$destination_folder" || { printf 'Caminho de destino inválido.\n'; return 1; }; fi
  if [ -n "$source_folder" ]; then relative_path=${source_path#"$source_folder"/}; else relative_path="$source_path"; fi
  if [ -n "$destination_folder" ]; then destination_path="$destination_folder/$relative_path"; else destination_path="$relative_path"; fi
  if [ "$source_path" = "$destination_path" ]; then printf 'Origem e destino são iguais; nada a mover.\n'; return 0; fi
  printf '\nOrigem  : %s\n' "$source_path"
  printf 'Destino : %s\n' "$destination_path"
  printf 'Confirma mover este arquivo? (s/n): '
  IFS= read -r answer
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
      IFS= read -r answer
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

show_menu() {
  local reset red green yellow blue magenta cyan white bold dim
  reset='\033[0m'; red='\033[31m'; green='\033[32m'; yellow='\033[33m'
  blue='\033[34m'; magenta='\033[35m'; cyan='\033[36m'; white='\033[97m'; bold='\033[1m'; dim='\033[2m'
  if [ ! -t 1 ] || [ -z "${TERM:-}" ] || [ "${TERM:-}" = dumb ]; then
    reset=''; red=''; green=''; yellow=''; blue=''; magenta=''; cyan=''; white=''; bold=''; dim=''
  fi
  if [ -t 1 ] && [ -n "${TERM:-}" ] && command -v clear >/dev/null 2>&1; then
    clear 2>/dev/null || :
  fi
  printf '\n%b╔══════════════════════════════════════════════════════════════════════════════╗%b\n' "$cyan$bold" "$reset"
  printf '%b║%b  %b   ██████╗ ██╗████████╗   %b  %bG I T   L O C A L%b  %b██████╗  %b║%b\n' "$cyan" "$reset" "$magenta$bold" "$reset" "$yellow$bold" "$reset" "$magenta$bold" "$cyan" "$reset"
  printf '%b║%b  %b   ╚═════╝ ╚═╝╚═══════╝   %b  %bGERENCIADOR GITHUB%b                 %b║%b\n' "$cyan" "$reset" "$magenta$bold" "$reset" "$white$bold" "$cyan" "$reset"
  printf '%b╠══════════════════════════════════════════════════════════════════════════════╣%b\n' "$cyan$bold" "$reset"
  printf '%b║%b Usuário GitHub: %-60s %b║%b\n' "$cyan" "$reset" "${GITHUB_USER:-Não autenticado}" "$cyan" "$reset"
  printf '%b╠══════════════════════════════════════════════════════════════════════════════╣%b\n' "$cyan$bold" "$reset"
  printf '%b║%b %bCRIAR%b                                  %bCONSULTAR%b                          %b║%b\n' "$cyan" "$reset" "$green$bold" "$reset" "$blue$bold" "$cyan" "$reset"
  printf '%b║%b %b 1%b Criar repositório na MAIN           %b 5%b Listar repositórios/subpastas MAIN%b║%b\n' "$cyan" "$reset" "$green$bold" "$reset" "$blue$bold" "$reset" "$cyan" "$reset"
  printf '%b║%b %b 2%b Criar BRANCH secundária vazia       %b 6%b Pesquisar arquivo/branch/caminho   %b║%b\n' "$cyan" "$reset" "$green$bold" "$reset" "$blue$bold" "$reset" "$cyan" "$reset"
  printf '%b║%b %b 3%b Criar pasta na MAIN                %b 7%b Listar arquivos locais              %b║%b\n' "$cyan" "$reset" "$green$bold" "$reset" "$blue$bold" "$reset" "$cyan" "$reset"
  printf '%b║%b %b 4%b Criar pasta na BRANCH              %b 8%b Listar arquivos do repositório MAIN %b║%b\n' "$cyan" "$reset" "$green$bold" "$reset" "$blue$bold" "$reset" "$cyan" "$reset"
  printf '%b║%b                                        %b 9%b Listar arquivos da BRANCH           %b║%b\n' "$cyan" "$reset" "$blue$bold" "$reset" "$cyan" "$reset"
  printf '%b╠══════════════════════════════════════════════════════════════════════════════╣%b\n' "$cyan$bold" "$reset"
  printf '%b║%b %bRENOMEAR%b                              %bMUDAR%b                               %b║%b\n' "$cyan" "$reset" "$yellow$bold" "$reset" "$magenta$bold" "$cyan" "$reset"
  printf '%b║%b %b10%b Renomear repositório                %b13%b Mudar diretório local              %b║%b\n' "$cyan" "$reset" "$yellow$bold" "$reset" "$magenta$bold" "$reset" "$cyan" "$reset"
  printf '%b║%b %b11%b Renomear BRANCH secundária         %b14%b Trocar usuário GitHub              %b║%b\n' "$cyan" "$reset" "$yellow$bold" "$reset" "$magenta$bold" "$reset" "$cyan" "$reset"
  printf '%b║%b %b12%b Renomear pasta da BRANCH           %b15%b Comparar arquivo local/remoto      %b║%b\n' "$cyan" "$reset" "$yellow$bold" "$reset" "$magenta$bold" "$reset" "$cyan" "$reset"
  printf '%b║%b                                        %b16%b Mover arquivo da MAIN              %b║%b\n' "$cyan" "$reset" "$magenta$bold" "$reset" "$cyan" "$reset"
  printf '%b║%b                                        %b17%b Mover arquivo da BRANCH            %b║%b\n' "$cyan" "$reset" "$magenta$bold" "$reset" "$cyan" "$reset"
  printf '%b╠══════════════════════════════════════════════════════════════════════════════╣%b\n' "$cyan$bold" "$reset"
  printf '%b║%b %bENVIAR%b                                 %bDELETAR%b                             %b║%b\n' "$cyan" "$reset" "$green$bold" "$reset" "$red$bold" "$cyan" "$reset"
  printf '%b║%b %b18%b Baixar arquivo remoto               %b21%b Deletar repositório da MAIN        %b║%b\n' "$cyan" "$reset" "$green$bold" "$reset" "$red$bold" "$reset" "$cyan" "$reset"
  printf '%b║%b %b19%b Enviar arquivo local ao GitHub      %b22%b Deletar BRANCH secundária          %b║%b\n' "$cyan" "$reset" "$green$bold" "$reset" "$red$bold" "$reset" "$cyan" "$reset"
  printf '%b║%b %b20%b Clonar repositório de terceiros     %b23%b Deletar pasta da MAIN              %b║%b\n' "$cyan" "$reset" "$green$bold" "$reset" "$red$bold" "$reset" "$cyan" "$reset"
  printf '%b║%b                                        %b24%b Deletar pasta da BRANCH            %b║%b\n' "$cyan" "$reset" "$red$bold" "$reset" "$cyan" "$reset"
  printf '%b║%b                                        %b25%b Deletar arquivo remoto             %b║%b\n' "$cyan" "$reset" "$red$bold" "$reset" "$cyan" "$reset"
  printf '%b╠══════════════════════════════════════════════════════════════════════════════╣%b\n' "$cyan$bold" "$reset"
  printf '%b║%b %b 0%b Sair                                                                       %b║%b\n' "$cyan" "$reset" "$white$bold" "$reset" "$cyan" "$reset"
  printf '%b╚══════════════════════════════════════════════════════════════════════════════╝%b\n' "$cyan$bold" "$reset"
  printf '\n%bEscolha uma opção:%b ' "$white$bold" "$reset"
}
main() {
  local option
  while :; do
    show_menu
    if ! IFS= read -r option; then
      printf '\nEntrada encerrada; saindo do menu.\n'
      break
    fi
    case "$option" in
      1) create_repository_main; pause ;;
      2) create_secondary_branch; pause ;;
      3) create_folder_main; pause ;;
      4) create_folder_secondary_branch; pause ;;
      5) list_repositories; pause ;;
      6) search_file; pause ;;
      7) list_local_files; pause ;;
      8) list_main_repository_files; pause ;;
      9) list_secondary_branch_files; pause ;;
      10) rename_repository; pause ;;
      11) rename_secondary_branch; pause ;;
      12) rename_folder_secondary_branch; pause ;;
      13) change_current_directory; pause ;;
      14) logout_github; login_github; pause ;;
      15) compare_local_remote_file; pause ;;
      16) move_main_repository_files; pause ;;
      17) move_secondary_branch_files; pause ;;
      18) download_file; pause ;;
      19) upload_file; pause ;;
      20) clone_third_party_repository; pause ;;
      21) delete_repository; pause ;;
      22) delete_secondary_branch; pause ;;
      23) delete_folder_main; pause ;;
      24) delete_folder_secondary_branch; pause ;;
      25) delete_remote_file; pause ;;
      0) logout_github; exit 0 ;;
      *) printf '\nOpção inválida.\n'; pause ;;
    esac
  done
}
command -v curl >/dev/null 2>&1 || {
  printf 'Erro: curl não está instalado.\n'
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'Erro: jq não está instalado.\n'
  exit 1
}
if [ ! -t 0 ]; then
  printf 'Erro: este programa precisa ser executado em um terminal interativo.\n' >&2
  printf 'Execute com: bash "%s"\n' "$0" >&2
  exit 2
fi

show_banner
if ! login_github; then
  printf '\nLogin não concluído. Programa encerrado.\n'
  exit 1
fi
main
