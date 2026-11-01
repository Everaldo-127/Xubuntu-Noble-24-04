#!/bin/bash

# Diagnóstico DNS Avançado
# Desenvolvido por Juninho & ChatGPT

VERMELHO=$(tput setaf 1)
VERDE=$(tput setaf 2)
AMARELO=$(tput setaf 3)
AZUL=$(tput setaf 6)
RESET=$(tput sgr0)
NEGRITO=$(tput bold)

PACOTES_REQUERIDOS=("dnsutils" "bind9-host")
COMANDOS=("nslookup" "dig" "host")

TIMEOUT_SEC=5
RETRIES=2
VERBOSITY=1

msg() {
  local level=$1; shift
  if [ "$VERBOSITY" -ge "$level" ]; then
    case $level in
      0) echo -e "${VERMELHO}${NEGRITO}$*${RESET}";;
      1) echo -e "${AZUL}$*${RESET}";;
      2) echo -e "${AMARELO}$*${RESET}";;
    esac
  fi
}

check_bash_version() {
  local ver="${BASH_VERSINFO[0]}"
  if [ "$ver" -lt 4 ]; then
    msg 0 "Bash versão 4.0 ou superior é obrigatória. Versão atual: $BASH_VERSION"
    exit 1
  fi
}

check_dependencies() {
  local faltando=()
  for cmd in "${COMANDOS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      faltando+=("$cmd")
    fi
  done
  if [ "${#faltando[@]}" -gt 0 ]; then
    msg 1 "Comandos ausentes: ${faltando[*]}"
    msg 1 "Deseja instalar pacotes necessários? (s/n)"
    read -r resposta
    if [[ "$resposta" =~ ^[Ss]$ ]]; then
      if ! command -v sudo &>/dev/null; then
        msg 0 "sudo não encontrado. Instale manualmente: sudo apt install dnsutils bind9-host -y"
        exit 1
      fi
      sudo apt update && sudo apt install -y "${PACOTES_REQUERIDOS[@]}"
    else
      msg 0 "Instalação recusada. Encerrando."
      exit 1
    fi
  fi
}

run_cmd() {
  local cmd=$1
  local output
  local attempt=1
  while [ $attempt -le $RETRIES ]; do
    output=$(timeout "$TIMEOUT_SEC" bash -c "$cmd" 2>&1)
    local code=$?
    if [ $code -eq 0 ]; then
      echo "$output"
      return 0
    else
      ((attempt++))
      msg 2 "Tentativa $((attempt-1)) falhou para comando: $cmd"
    fi
  done
  echo "$output"
  return 1
}

mostrar_problema() {
  ((problemas_detectados++))
  local erro="$1"
  local significado="$2"
  local causas="$3"
  local exemplo="$4"
  local solucao="$5"

  echo -e "${VERMELHO}${NEGRITO}[ERRO DETECTADO: $erro]${RESET}"
  echo -e "${AZUL}Significado detalhado:${RESET} $significado"
  echo -e "${AMARELO}Causas possíveis e impacto prático:${RESET} $causas"
  echo -e "${AMARELO}Exemplo real do impacto:${RESET} $exemplo"
  echo -e "${VERDE}Soluções recomendadas:${RESET} $solucao"
  echo "--------------------------------------------------"
}

validate_domain() {
  if [[ ! $DOMINIO =~ ^([a-zA-Z0-9_-]+\.)*[a-zA-Z0-9_-]+\.[a-zA-Z]{2,}(\.[a-zA-Z]{2,})?$ ]]; then
    msg 0 "Domínio inválido: $DOMINIO"
    exit 1
  fi
}

check_record() {
  local domain_to_check=$1
  local tipo=$2
  local rec=$(run_cmd "dig +short +nocmd +noall +answer $domain_to_check $tipo")
  echo "$rec"
}

check_inconsistency() {
  local record_type=$1
  local inconsistencias=$(dig $DOMINIO $record_type +short | sort | uniq -d)
  if [ -z "$inconsistencias" ]; then
    return
  fi
  mostrar_problema "Inconsistência DNS $record_type" \
    "Respostas diferentes encontradas entre servidores NS, indicando falha na sincronização da zona DNS." \
    "Pode causar resolução imprevisível e instabilidade no acesso ao domínio." \
    "Usuários podem ver conteúdos diferentes ou ter falhas de acesso dependendo da rota." \
    "Verifique e sincronize as zonas DNS em todos os servidores autoritativos."
}

# -----------------------
# Início do script
# -----------------------

check_bash_version
check_dependencies

echo -n "Informe o domínio a ser analisado (ex: www.exemplo.com): "
read -r DOMINIO

DOMINIO="${DOMINIO,,}"
DOMINIO="${DOMINIO#http://}"
DOMINIO="${DOMINIO#https://}"
DOMINIO="${DOMINIO%%/*}"

validate_domain

msg 1 "Iniciando Diagnóstico DNS para: $DOMINIO"
msg 1 "Verbosity level: $VERBOSITY"
msg 1 "--------------------------------------------------"

problemas_detectados=0

# Resolução básica (A e AAAA)
msg 1 "Executando resolução básica do domínio (A e AAAA)..."
IPV4=$(check_record "$DOMINIO" A)
IPV6=$(check_record "$DOMINIO" AAAA)

if [ -z "$IPV4" ] && [ -z "$IPV6" ]; then
  mostrar_problema "Falha na resolução básica" \
    "O domínio não retornou nenhum endereço IPv4 (A) ou IPv6 (AAAA)." \
    "Pode indicar domínio mal configurado ou inexistente." \
    "O site será inacessível, com erro de 'domínio não encontrado'." \
    "Verifique a configuração DNS junto ao provedor."
else
  msg 1 "${VERDE}[OK]${RESET} Resolução básica do domínio bem-sucedida."
  [ -n "$IPV4" ] && echo -e "IPv4: $IPV4"
  [ -n "$IPV6" ] && echo -e "IPv6: $IPV6"
fi

# Verificar inconsistências DNS
check_inconsistency A
check_inconsistency MX

# Registro MX
MX=$(check_record "$DOMINIO" MX)
if [ -z "$MX" ]; then
  mostrar_problema "MX ausente" \
    "O domínio não possui configuração de e-mail." \
    "E-mails não serão entregues nem recebidos." \
    "Formulários de contato, serviços SMTP falharão." \
    "Configure registros MX com seu provedor de e-mail."
fi

# Registro NS
NS=$(check_record "$DOMINIO" NS)
if [ -z "$NS" ]; then
  mostrar_problema "NS ausente" \
    "Sem servidores de nome (NS)." \
    "Domínio não será resolvido na internet." \
    "Usuários verão erro de DNS em qualquer acesso." \
    "Adicione registros NS válidos no registrador."
fi

# Registro SOA
SOA=$(check_record "$DOMINIO" SOA)
if [ -z "$SOA" ]; then
  mostrar_problema "SOA ausente" \
    "Sem registro de autoridade da zona." \
    "Zona DNS incompleta ou incorreta." \
    "Falhas de cache, propagação ou autenticação DNS." \
    "Adicione ou corrija o SOA na zona DNS."
fi

# TTL
TTL=$(dig $DOMINIO +noall +answer | awk '{print $2}' | sort -n | head -1)
if [[ "$TTL" =~ ^[0-9]+$ ]] && [ "$TTL" -lt 60 ]; then
  mostrar_problema "TTL muito baixo" \
    "O TTL (tempo de vida) dos registros DNS está configurado para menos de 60 segundos." \
    "Servidores DNS acabam sendo consultados com frequência excessiva, aumentando carga e latência." \
    "Usuário final pode experimentar lentidão e instabilidade no acesso ao site." \
    "Recomenda-se configurar TTL para valores entre 300 e 86400 segundos para equilibrar atualização e desempenho."
fi

# CNAME apontando para si mesmo (loop)
CNAME=$(check_record "$DOMINIO" CNAME)
if [[ "$CNAME" == *"$DOMINIO"* ]]; then
  mostrar_problema "CNAME apontando para si mesmo" \
    "Causa loop de resolução DNS." \
    "Redirecionamento circular impede acesso." \
    "Site não carrega, timeout em resoluções." \
    "Corrija o CNAME para apontar para domínio válido."
fi

msg 1 "${VERMELHO}${NEGRITO}Total de problemas detectados: $problemas_detectados${RESET}"
exit 0

