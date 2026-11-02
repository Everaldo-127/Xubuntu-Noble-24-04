#!/usr/bin/env bash
# Exibe o ambiente gráfico atual e as sessões disponíveis.
# Somente leitura; não requer sudo.

export LC_ALL=C

printf '\n'
printf 'SCRIPT: Consulta de ambientes gráficos e sessões instaladas\n'
printf 'OBJETIVO: Exibir o ambiente atual e as sessões disponíveis\n'
printf 'MODO: Somente leitura; não requer sudo\n\n'

if [[ -t 1 && -n "${TERM:-}" && "$TERM" != "dumb" ]]; then
    AZUL=$'\033[1;34m'
    CIANO=$'\033[1;36m'
    VERDE=$'\033[1;32m'
    AMARELO=$'\033[1;33m'
    MAGENTA=$'\033[1;35m'
    BRANCO=$'\033[1;37m'
    RESET=$'\033[0m'
else
    AZUL=''
    CIANO=''
    VERDE=''
    AMARELO=''
    MAGENTA=''
    BRANCO=''
    RESET=''
fi

titulos=(
    "RESUMO DOS AMBIENTES GRÁFICOS"
    "AMBIENTES"
    "SESSÕES DISPONÍVEIS"
)

largura_caixa=0
for titulo in "${titulos[@]}"; do
    largura=$(( ${#titulo} + 4 ))
    (( largura > largura_caixa )) && largura_caixa=$largura
done

linha_hash() {
    printf '%*s\n' "$largura_caixa" '' | tr ' ' '#'
}

cabecalho_caixa() {
    local texto="$1"
    local cor="$2"
    local interior=$(( largura_caixa - 2 ))
    local espacos_esquerda espacos_direita

    espacos_esquerda=$(( (interior - ${#texto}) / 2 ))
    espacos_direita=$(( interior - ${#texto} - espacos_esquerda ))

    printf '%s' "$cor"
    linha_hash
    printf '#%*s%s%s%s%*s#\n' \
        "$espacos_esquerda" '' "$BRANCO" "$texto" "$cor" \
        "$espacos_direita" ''
    linha_hash
    printf '%s\n' "$RESET"
}

ambiente_atual="${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-${XDG_SESSION_DESKTOP:-}}}"
[[ -n "$ambiente_atual" ]] || ambiente_atual="não identificado"

arquivos_sessao=()
for diretorio in /usr/share/xsessions /usr/share/wayland-sessions; do
    if [[ -d "$diretorio" ]]; then
        while IFS= read -r -d '' arquivo; do
            arquivos_sessao+=("$arquivo")
        done < <(
            find "$diretorio" -maxdepth 1 -type f -name '*.desktop' -print0 2>/dev/null
        )
    fi
done

printf '\n'
cabecalho_caixa "RESUMO DOS AMBIENTES GRÁFICOS" "$AZUL"

cabecalho_caixa "AMBIENTES" "$VERDE"
printf '  %sAMBIENTE ATUAL:%s %s%s%s\n\n' \
    "$VERDE" "$RESET" "$BRANCO" "$ambiente_atual" "$RESET"

cabecalho_caixa "SESSÕES DISPONÍVEIS" "$MAGENTA"

if ((${#arquivos_sessao[@]} > 0)); then
    nomes_sessao=()

    for arquivo in "${arquivos_sessao[@]}"; do
        nome="$(sed -n 's/^Name=//p' "$arquivo" | head -n 1)"
        [[ -n "$nome" ]] || nome="${arquivo##*/}"
        nomes_sessao+=("$nome")
    done

    mapfile -t nomes_sessao < <(printf '%s\n' "${nomes_sessao[@]}" | sort -fu)

    for nome in "${nomes_sessao[@]}"; do
        printf '  %s•%s %s\n' "$CIANO" "$RESET" "$nome"
    done
else
    printf '  %sNenhum arquivo de sessão encontrado.%s\n' "$AMARELO" "$RESET"
    printf '  %sLocais consultados: /usr/share/xsessions e /usr/share/wayland-sessions%s\n' \
        "$AMARELO" "$RESET"
fi

printf '\n%s' "$CIANO"
linha_hash
printf '%s\n' "$RESET"
printf '%sSomente sessões instaladas foram listadas.%s\n\n' "$CIANO" "$RESET"
