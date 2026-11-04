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
LOCAL_DIR_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/github-manager/current-directory"
# Compatibilidade com as funções do GitHub Manager Desktop: leitura de respostas no terminal.
gui_read() {
  local __gr_var="${1:-value}" __gr_val=""
  IFS= read -r __gr_val || __gr_val=""
  printf -v "$__gr_var" '%s' "$__gr_val"
}
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
  # Origem: sempre permite pasta (ENTER = RAIZ), inclusive na branch secundária
  printf 'Diretório de ORIGEM no repositório (ENTER para RAIZ): '
  gui_read source_folder
  source_folder=${source_folder#/}; source_folder=${source_folder%/}
  if [ -n "$source_folder" ]; then
    validate_remote_folder "$source_folder" || { printf 'Diretório de origem inválido.\n'; return 1; }
  else
    source_folder=""
    printf 'Pasta de origem: RAIZ.\n'
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

expand_user_path() {
  case "$1" in
    '~') printf '%s' "$HOME" ;;
    '~/'*) printf '%s' "$HOME/${1#\~/}" ;;
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$(get_local_base_dir)" "$1" ;;
  esac
}
attach_single_file() {
  local file rc
  ensure_login || return 1
  printf '\nDiretório local configurado: %s\n' "$(get_local_base_dir)"
  printf 'Arquivo a enviar (nome no diretório local ou caminho completo): '
  IFS= read -r file
  [ -n "$file" ] || { printf 'Nenhum arquivo informado.\n'; return 1; }
  file="$(expand_user_path "$file")"
  GITHUB_ATTACHMENTS_JSON=$(jq -n --arg f "$file" '[$f]') || return 1
  export GITHUB_ATTACHMENTS_JSON
  upload_selected_attachments; rc=$?
  unset GITHUB_ATTACHMENTS_JSON
  return "$rc"
}
attach_multiple_files() {
  local file rc
  local -a files=()
  ensure_login || return 1
  printf '\nDiretório local configurado: %s\n' "$(get_local_base_dir)"
  printf 'Informe um arquivo por linha (nome no diretório local ou caminho completo).\n'
  printf 'Linha vazia encerra a seleção.\n'
  while :; do
    printf 'Arquivo %s: ' "$(( ${#files[@]} + 1 ))"
    IFS= read -r file || break
    [ -n "$file" ] || break
    files+=("$(expand_user_path "$file")")
  done
  (( ${#files[@]} > 0 )) || { printf 'Nenhum arquivo selecionado.\n'; return 1; }
  GITHUB_ATTACHMENTS_JSON=$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .) || return 1
  export GITHUB_ATTACHMENTS_JSON
  upload_selected_attachments; rc=$?
  unset GITHUB_ATTACHMENTS_JSON
  return "$rc"
}

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
    '║  30 opções: repositórios, branches, pastas e arquivos (terminal).    ║' \
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
  local local_folder file_name dest_repo dest_branch dest_folder
  local local_path remote_path repo_encoded path_encoded
  local http_code sha status answer fsize resolved_dir
  ensure_login || return 1
  command -v base64 >/dev/null 2>&1 || { printf 'Erro: base64 não está disponível.\n'; return 1; }
  printf '\n=== ENVIAR ARQUIVO LOCAL AO GITHUB ===\n'
  printf 'Pasta local de ORIGEM (ENTER = diretório configurado): '
  gui_read local_folder
  if [ -z "$local_folder" ]; then
    resolved_dir="$(get_local_base_dir)" || return 1
  else
    case "$local_folder" in
      '~') local_folder="$HOME" ;;
      '~/'*) local_folder="$HOME/${local_folder#\~/}" ;;
      /*) ;;
      *) local_folder="$(get_local_base_dir)/$local_folder" ;;
    esac
    [ -d "$local_folder" ] || { printf 'Pasta local não encontrada: %s\n' "$local_folder"; return 1; }
    resolved_dir="$(cd -- "$local_folder" 2>/dev/null && pwd -P)" || {
      printf 'Não foi possível acessar a pasta local.\n'; return 1
    }
  fi
  printf 'Pasta local: %s\n' "$resolved_dir"
  printf 'Arquivos locais:\n'
  find "$resolved_dir" -maxdepth 1 -type f -printf '  %f\n' 2>/dev/null | sort || true
  printf 'Nome do arquivo local (com extensão, sem caminho): '
  gui_read file_name
  case "$file_name" in ""|"."|".."|*/*|*\\*) printf 'Informe somente o nome do arquivo, sem caminhos.\n'; return 1 ;; esac
  local_path="$resolved_dir/$file_name"
  [[ -f "$local_path" && ! -L "$local_path" ]] || { printf 'Arquivo não encontrado: %s\n' "$local_path"; return 1; }
  [ -r "$local_path" ] || { printf 'Sem permissão de leitura: %s\n' "$local_path"; return 1; }
  fsize=$(wc -c < "$local_path" 2>/dev/null || echo 0)
  if [ "$fsize" -gt 104857600 ]; then
    printf 'Erro: arquivo acima de 100 MB. Use git commit/push ou Git LFS.\n'
    return 1
  fi
  printf 'Repositório de DESTINO: '
  gui_read dest_repo
  valid_name "$dest_repo" || { printf 'Nome de repositório inválido.\n'; return 1; }
  repo_encoded=$(urlencode "$dest_repo") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded" "" "$TMP_DIR/up-local-repo.json"; then return 1; fi
  DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$TMP_DIR/up-local-repo.json")
  printf 'Branch de DESTINO (ENTER = MAIN = %s): ' "$DEFAULT_BRANCH"
  gui_read dest_branch
  [ -n "$dest_branch" ] || dest_branch="$DEFAULT_BRANCH"
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/branches/$(urlencode "$dest_branch")" "" "$TMP_DIR/up-local-branch.json"; then
    printf 'Branch de destino não encontrada: %s\n' "$dest_branch"
    return 1
  fi
  printf 'Pasta de DESTINO no GitHub (ENTER para RAIZ): '
  gui_read dest_folder
  dest_folder=${dest_folder#/}; dest_folder=${dest_folder%/}
  if [ -n "$dest_folder" ]; then
    validate_remote_folder "$dest_folder" || { printf 'Pasta de destino inválida.\n'; return 1; }
    remote_path="$dest_folder/$file_name"
  else
    remote_path="$file_name"
  fi
  printf '\nLocal   : %s\n' "$local_path"
  printf 'Destino : %s / %s / %s\n' "$dest_repo" "$dest_branch" "$remote_path"
  printf 'Confirma o envio? (s/n): '
  gui_read answer
  case "$answer" in s|S|sim|SIM) ;; *) printf 'Operação cancelada.\n'; return 0 ;; esac
  if ! base64 < "$local_path" | tr -d '\r\n' > "$TMP_DIR/upload-content.b64"; then
    printf 'Erro ao codificar o arquivo.\n'; return 1
  fi
  path_encoded=$(urlencode_path "$remote_path") || return 1
  http_code=$(curl -sS -o "$TMP_DIR/content.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$path_encoded?ref=$(urlencode "$dest_branch")") || http_code=000
  sha=""
  case "$http_code" in
    200)
      sha=$(jq -r '.sha // empty' "$TMP_DIR/content.json")
      printf 'O arquivo remoto já existe. Atualizar? (s/n): '
      gui_read answer
      case "$answer" in s|S|sim|SIM) ;; *) printf 'Remoto mantido. Envio cancelado.\n'; return 0 ;; esac
      [ -n "$sha" ] || { printf 'SHA remoto indisponível.\n'; return 1; }
      ;;
    404) ;;
    *) printf 'Erro ao consultar remoto (HTTP %s).\n' "$http_code"; return 1 ;;
  esac
  if ! jq -n --arg message "Envio de $remote_path via GitHub Manager" \
    --rawfile content "$TMP_DIR/upload-content.b64" --arg branch "$dest_branch" --arg sha "$sha" \
    '{message:$message,content:($content|gsub("[\\r\\n]";"")),branch:$branch} + (if $sha != "" then {sha:$sha} else {} end)' \
    > "$TMP_DIR/upload-payload.json"; then
    printf 'Erro ao preparar o envio.\n'; return 1
  fi
  status=$(curl -sS -o "$TMP_DIR/upload.json" -w '%{http_code}' -X PUT \
    -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" -H 'Content-Type: application/json' \
    --data-binary "@$TMP_DIR/upload-payload.json" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$path_encoded") || status=000
  case "$status" in
    200|201)
      if jq -e '.content.sha and .commit.sha' "$TMP_DIR/upload.json" >/dev/null 2>&1; then
        printf 'Arquivo enviado: %s -> %s/%s/%s\n' "$file_name" "$dest_repo" "$dest_branch" "$remote_path"
      else
        printf 'A API não confirmou o envio.\n'; return 1
      fi
      ;;
    *) printf 'Falha no envio (HTTP %s).\n' "$status"; jq -r '.message // empty' "$TMP_DIR/upload.json" 2>/dev/null; return 1 ;;
  esac
}


delete_remote_file() {
  local repo branch folder file_name path message sha payload answer
  local repo_encoded encoded_path candidate matched_path expected_path
  ensure_login || return 1
  printf '\n=== EXCLUIR ARQUIVO REMOTO ===\n'
  printf 'Nome do repositório: '
  gui_read repo
  valid_name "$repo" || { printf 'Nome de repositório inválido.\n'; return 1; }
  repo_encoded=$(urlencode "$repo") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded" "" "$TMP_DIR/del-file-repo.json"; then return 1; fi
  DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$TMP_DIR/del-file-repo.json")
  SELECTED_REPO="$repo"
  printf 'Branch (ENTER para MAIN = %s): ' "$DEFAULT_BRANCH"
  gui_read branch
  [ -n "$branch" ] || branch="$DEFAULT_BRANCH"
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/branches/$(urlencode "$branch")" "" "$TMP_DIR/del-file-branch.json"; then
    printf 'Branch não encontrada: %s\n' "$branch"; return 1
  fi
  printf 'Pasta (ENTER para RAIZ): '
  gui_read folder
  folder=${folder#/}; folder=${folder%/}
  if [ -n "$folder" ]; then
    validate_remote_folder "$folder" || { printf 'Caminho de pasta inválido.\n'; return 1; }
  fi
  remote_file_paths "$repo" "$branch" "$folder" || return 1
  if [ ! -s "$TMP_DIR/remote-files-paths.txt" ]; then
    printf 'Nenhum arquivo encontrado nessa pasta/branch.\n'; return 1
  fi
  printf '\nArquivos na pasta "%s" (branch %s):\n' "${folder:-/}" "$branch"
  cat "$TMP_DIR/remote-files-paths.txt"
  printf '\nNome do arquivo a excluir (com extensão, sem caminho): '
  gui_read file_name
  [ -n "$file_name" ] || { printf 'Nome de arquivo não informado.\n'; return 1; }
  case "$file_name" in */*|*\\*) printf 'Informe somente o nome do arquivo, sem caminhos.\n'; return 1 ;; esac
  # Caminho exato dentro da pasta escolhida (ou RAIZ) — evita ambiguidade entre
  # arquivos de mesmo nome em subpastas diferentes.
  if [ -n "$folder" ]; then
    expected_path="$folder/$file_name"
  else
    expected_path="$file_name"
  fi
  matched_path=""
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ "$candidate" = "$expected_path" ]; then matched_path="$candidate"; break; fi
  done < "$TMP_DIR/remote-files-paths.txt"
  if [ -z "$matched_path" ]; then
    printf 'Arquivo "%s" não encontrado na pasta "%s".\n' "$file_name" "${folder:-/}"
    return 1
  fi
  path="$matched_path"
  encoded_path=$(urlencode_path "$path") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path?ref=$(urlencode "$branch")" "" "$TMP_DIR/content.json"; then
    return 1
  fi
  sha=$(jq -r '.sha // empty' "$TMP_DIR/content.json")
  [ -n "$sha" ] || { printf 'Não foi possível obter o SHA do arquivo.\n'; return 1; }
  printf 'Mensagem do commit de exclusão: '
  gui_read message
  [ -n "$message" ] || message="Exclusão de $path via GitHub Manager"
  printf '\nRepositório : %s\nBranch      : %s\nArquivo     : %s\n' "$repo" "$branch" "$path"
  printf 'Confirma a exclusão? (s/n): '
  gui_read answer
  case "$answer" in s|S|sim|SIM) ;; *) printf 'Operação cancelada.\n'; return 0 ;; esac
  payload=$(jq -n --arg message "$message" --arg sha "$sha" --arg branch "$branch" '{message:$message,sha:$sha,branch:$branch}')
  if api DELETE "/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path" "$payload"; then
    printf 'Arquivo excluído: %s\n' "$path"
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
  printf 'Branch           : %s\n' "$branch_name"
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
  local repo
  ensure_login || return 1
  printf '\n=== RENOMEAR PASTA ===\n'
  printf 'Nome do repositório: '
  gui_read repo
  valid_name "$repo" || { printf 'Nome de repositório inválido.\n'; return 1; }
  repo_encoded=$(urlencode "$repo") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded" "" "$TMP_DIR/rename-folder-repo.json"; then return 1; fi
  DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$TMP_DIR/rename-folder-repo.json")
  SELECTED_REPO="$repo"
  printf 'Branch (ENTER para MAIN = %s): ' "$DEFAULT_BRANCH"
  gui_read branch_name
  [ -n "$branch_name" ] || branch_name="$DEFAULT_BRANCH"
  branch_ref_encoded=$(urlencode_path "$branch_name") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/git/ref/heads/$branch_ref_encoded" "" "$TMP_DIR/rename-folder-branch-ref.json"; then
    printf 'A branch não foi localizada: %s\n' "$branch_name"
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

show_menu() {
  local reset='' bold=''
  local c0='' c1='' c2='' c3='' c4='' c5='' c6='' cw='' cnum='' cnumbg='' ctxt=''
  local cols gap col_w total_w left_pad i r nlines
  local -a titles colors
  local -a items0 items1 items2 items3 items4 items5 items6
  local -a lines0 lines1 lines2 lines3 lines4 lines5 lines6
  local -a flags0 flags1 flags2 flags3 flags4 flags5 flags6

  if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != dumb ]; then
    local esc=$'\033'
    reset="${esc}[0m"; bold="${esc}[1m"; cw="${esc}[97m"
    cnum="${esc}[30;1m"          # número preto negrito
    cnumbg="${esc}[47m"          # preenchimento branco do badge (alto contraste)
    ctxt="${esc}[1m"             # texto do menu em negrito (destaque)
    c0="${esc}[33m"; c1="${esc}[32m"; c2="${esc}[31m"
    c3="${esc}[35m"; c4="${esc}[34m"; c5="${esc}[95m"; c6="${esc}[38;5;214m"
  fi
  if [ -t 1 ] && [ -n "${TERM:-}" ] && command -v clear >/dev/null 2>&1; then
    clear 2>/dev/null || :
  fi

  cols=$(tput cols 2>/dev/null || echo 120)
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=120
  [ "$cols" -lt 60 ] && cols=60
  [ "$cols" -gt 200 ] && cols=200

  gap=3
  # Largura de coluna sempre cabe na tela (7 colunas + 6 separadores)
  col_w=$(( (cols - 6 * gap) / 7 ))
  [ "$col_w" -lt 8 ] && col_w=8
  total_w=$(( col_w * 7 + 6 * gap ))
  while [ "$total_w" -gt "$cols" ] && [ "$col_w" -gt 8 ]; do
    col_w=$((col_w - 1))
    total_w=$(( col_w * 7 + 6 * gap ))
  done
  left_pad=$(( (cols - total_w) / 2 ))
  [ "$left_pad" -lt 0 ] && left_pad=0

  # Badge fixo do número: sempre 4 colunas visuais -> [NN] com preenchimento
  # Formato visual: fundo + " NN " (número centralizado em 4 chars)
  NUM_W=4

  pad_exact() {
    local s="$1" w="$2" t pad
    t="${s:0:w}"
    pad=$(( w - ${#t} ))
    [ "$pad" -lt 0 ] && pad=0
    printf '%s%*s' "$t" "$pad" ''
  }

  wrap_into() {
    local text="$1" w="$2" arrname="$3"
    local rest chunk line
    local -n _arr="$arrname"
    _arr=()
    rest="$text"
    while [ -n "$rest" ]; do
      if [ "${#rest}" -le "$w" ]; then
        _arr+=("$rest")
        break
      fi
      chunk="${rest:0:w}"
      if [[ "$chunk" == *' '* ]]; then
        line="${chunk% *}"
        if [ -z "$line" ]; then
          line="$chunk"
          rest="${rest:${#line}}"
        else
          rest="${rest:$((${#line}+1))}"
        fi
      else
        line="$chunk"
        rest="${rest:w}"
      fi
      rest="${rest#"${rest%%[![:space:]]*}"}"
      _arr+=("$line")
    done
  }

  titles=(
    "COMPARAR / MOVER"
    "CONSULTAR"
    "EXCLUIR"
    "ENVIAR ARQUIVOS"
    "CRIAR"
    "RENOMEAR"
    "MUDAR / LOGOFF"
  )
  colors=("$c0" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6")

  items0=(
    "01 Comparar arquivo local/remoto"
    "02 Mover arquivo da MAIN"
    "03 Mover arquivo da BRANCH"
    "04 MOVER TODOS arquivos da BRANCH main para pasta"
    "05 MOVER TODOS arquivos da BRANCH secundária para pasta"
    "06 Enviar TODOS arquivos de qualquer pasta para..."
  )
  items1=(
    "07 Listar repositórios e pastas"
    "08 Pesquisar arquivo / caminho"
    "09 Listar arquivos locais"
    "10 Listar arquivos da MAIN"
    "11 Listar arquivos da BRANCH"
  )
  items2=(
    "12 Excluir REPOSITÓRIO"
    "13 Excluir BRANCH secundária"
    "14 Excluir pasta do REPOSITÓRIO"
    "15 Excluir pasta da BRANCH secundária"
    "16 Excluir arquivo remoto"
  )
  items3=(
    "17 Baixar arquivo remoto"
    "18 Enviar arquivo ao GitHub"
    "19 Clonar repositório de terceiros"
    "20 Enviar arquivo em anexo"
    "21 Enviar diversos anexos"
  )
  items4=(
    "22 Criar REPOSITÓRIO"
    "23 Criar BRANCH secundária"
    "24 Criar PASTA no REPOSITÓRIO"
    "25 Criar pasta na BRANCH"
  )
  items5=(
    "26 Renomear repositório"
    "27 Renomear BRANCH secundária"
    "28 Renomear pasta da BRANCH"
  )
  items6=(
    "29 Mudar diretório local"
    "30 Trocar usuário GitHub"
  )

  build_col() {
    local srcname="$1" linesname="$2" flagsname="$3"
    local -n _src="$srcname"
    local -n _lines="$linesname"
    local -n _flags="$flagsname"
    local it num body wbody cont k
    local -a wrapped=()
    _lines=()
    _flags=()
    for it in "${_src[@]}"; do
      num="${it%% *}"
      body="${it#* }"
      # espaço para badge (4) + 1 espaço + texto
      wbody=$(( col_w - NUM_W - 1 ))
      [ "$wbody" -lt 6 ] && wbody=6
      wrapped=()
      wrap_into "$body" "$wbody" wrapped
      if [ "${#wrapped[@]}" -eq 0 ]; then
        _lines+=("$num|")
        _flags+=(1)
      else
        _lines+=("${num}|${wrapped[0]}")
        _flags+=(1)
        for ((k=1; k<${#wrapped[@]}; k++)); do
          # continuação: sem número, alinhada após o badge
          cont=$(printf '%*s%s' $((NUM_W + 1)) '' "${wrapped[$k]}")
          _lines+=("|$cont")
          _flags+=(0)
        done
      fi
      # quebra visual entre opções
      _lines+=("|")
      _flags+=(0)
    done
    # remove linha em branco final extra da coluna
    if [ "${#_lines[@]}" -gt 0 ]; then
      unset "_lines[-1]"
      unset "_flags[-1]"
    fi
  }

  build_col items0 lines0 flags0
  build_col items1 lines1 flags1
  build_col items2 lines2 flags2
  build_col items3 lines3 flags3
  build_col items4 lines4 flags4
  build_col items5 lines5 flags5
  build_col items6 lines6 flags6

  nlines=${#lines0[@]}
  [ ${#lines1[@]} -gt "$nlines" ] && nlines=${#lines1[@]}
  [ ${#lines2[@]} -gt "$nlines" ] && nlines=${#lines2[@]}
  [ ${#lines3[@]} -gt "$nlines" ] && nlines=${#lines3[@]}
  [ ${#lines4[@]} -gt "$nlines" ] && nlines=${#lines4[@]}
  [ ${#lines5[@]} -gt "$nlines" ] && nlines=${#lines5[@]}
  [ ${#lines6[@]} -gt "$nlines" ] && nlines=${#lines6[@]}

  print_cell() {
    local bi="$1" ri="$2"
    local raw="" flag=0 num="" rest="" plain badge
    case "$bi" in
      0) [ "$ri" -lt "${#lines0[@]}" ] && { raw="${lines0[$ri]}"; flag="${flags0[$ri]:-0}"; } ;;
      1) [ "$ri" -lt "${#lines1[@]}" ] && { raw="${lines1[$ri]}"; flag="${flags1[$ri]:-0}"; } ;;
      2) [ "$ri" -lt "${#lines2[@]}" ] && { raw="${lines2[$ri]}"; flag="${flags2[$ri]:-0}"; } ;;
      3) [ "$ri" -lt "${#lines3[@]}" ] && { raw="${lines3[$ri]}"; flag="${flags3[$ri]:-0}"; } ;;
      4) [ "$ri" -lt "${#lines4[@]}" ] && { raw="${lines4[$ri]}"; flag="${flags4[$ri]:-0}"; } ;;
      5) [ "$ri" -lt "${#lines5[@]}" ] && { raw="${lines5[$ri]}"; flag="${flags5[$ri]:-0}"; } ;;
      6) [ "$ri" -lt "${#lines6[@]}" ] && { raw="${lines6[$ri]}"; flag="${flags6[$ri]:-0}"; } ;;
    esac
    if [ "$flag" = 1 ]; then
      num="${raw%%|*}"
      rest="${raw#*|}"
      # badge 4 chars com número centralizado: " 01 " / " 09 " / " 30 "
      badge=$(printf '%2s' "$num")
      badge=$(printf '%-4s' " $badge")
      badge="${badge:0:4}"
      # texto à direita do badge
      rest=$(pad_exact " $rest" $((col_w - NUM_W)))
      printf '%b%s%b%b%s%b' "${cnumbg}${cnum}" "$badge" "$reset" "${colors[$bi]}$ctxt" "$rest" "$reset"
    else
      rest="${raw#*|}"
      printf '%b%s%b' "${colors[$bi]}$ctxt" "$(pad_exact "$rest" "$col_w")" "$reset"
    fi
  }

  rule_sep() {
    printf '%*s' "$left_pad" ''
    local i
    for i in 0 1 2 3 4 5 6; do
      printf '%b' "${colors[$i]}"
      printf '%*s' "$col_w" '' | tr ' ' '-'
      printf '%b' "$reset"
      [ "$i" -lt 6 ] && printf '%b-+-%b' "$cw" "$reset"
    done
    printf '\n'
  }

  # ===== CABEÇALHO (largura estrita = cols, sem corte) =====
  line_fill() {
    local ch="${1:--}" n="$2"
    n=$((n+0)); [ "$n" -lt 0 ] && n=0
    [ "$n" -gt 300 ] && n=300
    printf '%*s' "$n" '' | tr ' ' "$ch"
  }
  clip() { printf '%s' "${1:0:$2}"; }
  pad_left() {
    local s="$1" w="$2" t p
    t=$(clip "$s" "$w")
    p=$(( w - ${#t} )); [ "$p" -lt 0 ] && p=0
    printf '%s%*s' "$t" "$p" ''
  }
  center() {
    local s="$1" w="$2" t pl pr
    t=$(clip "$s" "$w")
    pl=$(( (w - ${#t}) / 2 )); [ "$pl" -lt 0 ] && pl=0
    pr=$(( w - ${#t} - pl )); [ "$pr" -lt 0 ] && pr=0
    printf '%*s%s%*s' "$pl" '' "$t" "$pr" ''
  }

  printf '%b' "${c0}${bold}"; line_fill '-' "$cols"; printf '%b\n' "$reset"
  printf '%b%s%b\n' "${c0}${bold}" "$(center "GIT LOCAL | CENTRO DE COMANDO GITHUB" "$cols")" "$reset"
  printf '%b%s%b\n' "${c0}" "$(center "Repositorios / Branches / Pastas / Arquivos (CLI)" "$cols")" "$reset"
  printf '%b' "${c0}${bold}"; line_fill '-' "$cols"; printf '%b\n' "$reset"

  # Duas colunas que somam exatamente $cols (lw + 1 + rw = cols)
  local lw rw
  lw=$(( cols / 2 - 1 ))
  rw=$(( cols - lw - 1 ))
  [ "$lw" -lt 18 ] && lw=18
  rw=$(( cols - lw - 1 ))
  [ "$rw" -lt 18 ] && { rw=18; lw=$(( cols - rw - 1 )); }

  local -a IL IR
  IL=(
    "INSTRUCOES"
    "1. Digite 0-30 e ENTER"
    "2. Zero (0) encerra"
    "3. Responda no terminal"
    "4. PAT so nesta sessao"
    "5. Destrutivo confirma"
  )
  IR=(
    "LICENCA"
    "Direitos reservados."
    "Sem licenca open source."
    "Uso sob sua responsabilidade."
    "curl, jq, Bash, GitHub API"
    "mantem licencas originais."
  )
  local i
  for i in 0 1 2 3 4 5; do
    if [ "$i" -eq 0 ]; then
      printf '%b%s%b %b%s%b\n' \
        "${c0}${bold}" "$(pad_left "${IL[$i]}" "$lw")" "$reset" \
        "${c0}${bold}" "$(pad_left "${IR[$i]}" "$rw")" "$reset"
    else
      printf '%s %s\n' "$(pad_left "${IL[$i]}" "$lw")" "$(pad_left "${IR[$i]}" "$rw")"
    fi
  done

  printf '%b' "${c0}${bold}"; line_fill '-' "$cols"; printf '%b\n' "$reset"

  local half=$(( cols / 2 ))
  local other=$(( cols - half ))
  printf '%b%s%b%s\n' \
    "${c0}${bold}" \
    "$(pad_left "Usuario: ${GITHUB_USER:-Nao autenticado}" "$half")" \
    "$reset" \
    "$(pad_left "Local: $(get_local_base_dir)" "$other")"
  printf '\n'

  # Títulos dos blocos
  printf '%*s' "$left_pad" ''
  for i in 0 1 2 3 4 5 6; do
    printf '%b%s%b' "${colors[$i]}${bold}" "$(pad_exact "${titles[$i]}" "$col_w")" "$reset"
    [ "$i" -lt 6 ] && printf '%b | %b' "$cw" "$reset"
  done
  printf '\n'

  rule_sep

  for ((r=0; r<nlines; r++)); do
    printf '%*s' "$left_pad" ''
    for i in 0 1 2 3 4 5 6; do
      print_cell "$i" "$r"
      [ "$i" -lt 6 ] && printf '%b | %b' "$cw" "$reset"
    done
    printf '\n'
  done

  rule_sep

  printf '%b' "${c0}${bold}"
  printf '%*s' "$cols" '' | tr ' ' '-'
  printf '%b\n' "$reset"
  printf '  %b 0 %b Sair   %bEscolha (0-30):%b ' "${cnumbg}${cnum}" "$reset" "${cw}${bold}" "$reset"
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
      1) compare_local_remote_file; pause ;;
      2) move_main_repository_files; pause ;;
      3) move_secondary_branch_files; pause ;;
      4) move_all_repository_folder_files; pause ;;
      5) move_all_main_branch_files; pause ;;
      6) move_all_secondary_branch_files; pause ;;
      7) list_repositories; pause ;;
      8) search_file; pause ;;
      9) list_local_files; pause ;;
      10) list_main_repository_files; pause ;;
      11) list_secondary_branch_files; pause ;;
      12) delete_repository; pause ;;
      13) delete_secondary_branch; pause ;;
      14) delete_folder_main; pause ;;
      15) delete_folder_secondary_branch; pause ;;
      16) delete_remote_file; pause ;;
      17) download_file; pause ;;
      18) upload_file; pause ;;
      19) clone_third_party_repository; pause ;;
      20) attach_single_file; pause ;;
      21) attach_multiple_files; pause ;;
      22) create_repository_main; pause ;;
      23) create_secondary_branch; pause ;;
      24) create_folder_main; pause ;;
      25) create_folder_secondary_branch; pause ;;
      26) rename_repository; pause ;;
      27) rename_secondary_branch; pause ;;
      28) rename_folder_secondary_branch; pause ;;
      29) change_current_directory; pause ;;
      30) logout_github; login_github; pause ;;
      0) logout_github; exit 0 ;;
      *) printf '\nOpção inválida. Informe um número de 0 a 30.\n'; pause ;;
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
