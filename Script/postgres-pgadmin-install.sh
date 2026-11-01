#!/bin/bash
set -euo pipefail

# =====================================================================
# Script robusto e seguro para instalação do PostgreSQL e pgAdmin 4
# em Xubuntu Minimal 24.04, com foco em:
# - Verificação e instalação de pacotes essenciais antes de iniciar.
# - Backup e saneamento criterioso de repositórios, eliminando duplicações.
# - Correção de chaves GPG usando múltiplos métodos, com controle de permissões.
# - Instalação do PostgreSQL e pgAdmin 4 com validação pós-instalação.
# - Inicialização e verificação do serviço PostgreSQL.
# - Tratamento avançado de erros sem abortar a execução.
# - Logs detalhados para auditoria e diagnóstico.
# - Prevenção de falhas comuns (rede, permissões, espaço, sudo).
# - Correção dos repositórios ao final para evitar conflitos e garantir coerência.
# =====================================================================

# ===========================
# Configurações de cores para saída
# ===========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

# ===========================
# Variáveis de log e backup
# ===========================
LOG_DIR="/home/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/postgres_pgadmin_install_$(date +%Y%m%d_%H%M%S).log"
REPO_BACKUP_DIR="/etc/apt/sources.list.d/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$REPO_BACKUP_DIR"

# ===========================
# Função para registrar logs com timestamp
# ===========================
log() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# ===========================
# Função para tratar erros sem abortar
# ===========================
handle_error() {
  local msg="$1"
  log "${RED}[ERRO] $msg${NC}"
}

# ===========================
# Função para rodar comandos sudo com tratamento
# ===========================
sudo_run() {
  if ! sudo "$@"; then
    handle_error "Falha no comando sudo: sudo $*"
    return 1
  fi
  return 0
}

# ===========================
# Verifica conexão de rede com timeout para evitar falhas silenciosas
# ===========================
check_network() {
  log "${YELLOW}Verificando conectividade de rede...${NC}"
  if ! timeout 5 ping -c 1 8.8.8.8 &>/dev/null; then
    handle_error "Rede indisponível: não foi possível alcançar 8.8.8.8"
    return 1
  fi
  log "${GREEN}Rede está ativa.${NC}"
  return 0
}

# ===========================
# Verifica espaço em disco disponível no /var/cache/apt
# ===========================
check_disk_space() {
  log "${YELLOW}Verificando espaço em disco para cache APT...${NC}"
  local space_kb
  space_kb=$(df --output=avail /var/cache/apt | tail -1)
  if (( space_kb < 524288 )); then  # Menos que 512MB disponível
    handle_error "Espaço insuficiente em disco para operações APT: ${space_kb}KB disponíveis"
    return 1
  fi
  log "${GREEN}Espaço em disco suficiente: ${space_kb}KB disponíveis.${NC}"
  return 0
}

# ===========================
# Função para verificar e instalar pacotes essenciais
# ===========================
verificar_instalar_pacotes() {
  log "${YELLOW}Verificando pacotes essenciais...${NC}"
  local pacotes=("curl" "gpg" "software-properties-common" "apt-transport-https" "ca-certificates" "dirmngr" "wget")
  for pkg in "${pacotes[@]}"; do
    if ! dpkg -l "$pkg" &>/dev/null; then
      log "${BLUE}Pacote ausente: $pkg. Instalando...${NC}"
      if ! sudo_run apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1; then
        handle_error "Falha ao instalar $pkg"
      fi
    else
      log "${GREEN}Pacote já instalado: $pkg${NC}"
    fi
  done
}

# ===========================
# Backup e saneamento criterioso dos arquivos de repositório
# ===========================
backup_e_saneamento_repos() {
  log "${YELLOW}Backup e saneamento dos repositórios...${NC}"

  # Backup principal do sources.list
  if sudo_run cp /etc/apt/sources.list /etc/apt/sources.list.bak; then
    log "Backup do sources.list criado."
  else
    handle_error "Falha ao criar backup de /etc/apt/sources.list"
  fi

  # Backup e verificação de duplicação para ubuntu.sources
  if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    sudo_run cp /etc/apt/sources.list.d/ubuntu.sources "${REPO_BACKUP_DIR}/ubuntu.sources.bak"
    log "Backup de ubuntu.sources criado."

    # Verifica duplicações com grep e elimina apenas linhas duplicadas em ubuntu.sources sem apagar arquivo inteiro
    local dups
    dups=$(grep -Fxf /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources || true)
    if [ -n "$dups" ]; then
      log "${RED}Linhas duplicadas detectadas em ubuntu.sources, eliminando duplicatas...${NC}"
      # Remove linhas duplicadas da ubuntu.sources criando temporário
      sudo_run awk 'NR==FNR{a[$0]++;next} a[$0]<2' /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources | sudo tee /etc/apt/sources.list.d/ubuntu.sources.tmp > /dev/null
      sudo_run mv /etc/apt/sources.list.d/ubuntu.sources.tmp /etc/apt/sources.list.d/ubuntu.sources
      log "Duplicatas removidas de ubuntu.sources."
    else
      log "Nenhuma duplicata detectada em ubuntu.sources."
    fi
  else
    log "Arquivo ubuntu.sources não encontrado, nada a sanear."
  fi

  # Atualiza cache apt e valida duplicatas globais
  if ! sudo_run apt-get update >> "$LOG_FILE" 2>&1; then
    handle_error "apt update falhou após saneamento inicial"
  fi

  # Última validação para duplicatas e remoção definitiva se persistirem
  local persist_duplicatas
  persist_duplicatas=$(sudo apt-get update 2>&1 | grep "configured multiple times" || true)
  if [ -n "$persist_duplicatas" ]; then
    log "${RED}Duplicatas persistem após saneamento:${NC}\n$persist_duplicatas"
    # Identifica arquivo conflitante e move para backup (exceto sources.list)
    local conflicted_file
    conflicted_file=$(echo "$persist_duplicatas" | grep -oP '(?<=and ).*\.list(?=:)' | head -1 || true)
    if [ -n "$conflicted_file" ] && [ "$conflicted_file" != "/etc/apt/sources.list" ]; then
      sudo_run mv "$conflicted_file" "${REPO_BACKUP_DIR}/"
      log "Arquivo $conflicted_file movido para backup para eliminar conflito."
      sudo_run apt-get update >> "$LOG_FILE" 2>&1 || handle_error "apt update falhou após mover arquivo conflitante"
    else
      handle_error "Não foi possível resolver duplicatas automaticamente."
    fi
  else
    log "${GREEN}Repositórios limpos, sem duplicatas persistentes.${NC}"
  fi
}

# ===========================
# Correção de chaves GPG usando métodos múltiplos com permissões seguras
# ===========================
corrigir_chave_gpg() {
  local url="$1"
  local output="$2"
  log "${YELLOW}Corrigindo chave GPG para $output${NC}"

  # Remove chave antiga se existir
  sudo_run rm -f "$output" || true

  # 1) curl + gpg --dearmor
  if curl -fsSL "$url" 2>>"$LOG_FILE" | sudo gpg --dearmor -o "$output" 2>>"$LOG_FILE"; then
    sudo_run chmod 644 "$output"
    log "${GREEN}Chave instalada pelo método 1${NC}"
    return 0
  fi

  # 2) wget + gpg --dearmor
  if wget -qO - "$url" 2>>"$LOG_FILE" | gpg --dearmor | sudo tee "$output" > /dev/null 2>>"$LOG_FILE"; then
    sudo_run chmod 644 "$output"
    log "${GREEN}Chave instalada pelo método 2${NC}"
    return 0
  fi

  # 3) apt-key add (deprecated, fallback)
  if curl -fsSL "$url" 2>>"$LOG_FILE" | sudo apt-key add - >> "$LOG_FILE" 2>&1; then
    log "${GREEN}Chave instalada pelo método 3 (apt-key)${NC}"
    return 0
  fi

  # 4) gpg com keyring temporário
  local tmpkey="/tmp/tempkey_$(date +%s).gpg"
  if curl -fsSL "$url" -o "$tmpkey" 2>>"$LOG_FILE" && gpg --no-default-keyring --keyring "$tmpkey" --dearmor | sudo tee "$output" > /dev/null 2>>"$LOG_FILE"; then
    sudo_run chmod 644 "$output"
    rm -f "$tmpkey"
    log "${GREEN}Chave instalada pelo método 4${NC}"
    return 0
  fi

  # 5) download manual + mv
  local manualtmp="/tmp/manualkey_$(date +%s).asc"
  if curl -fsSL "$url" -o "$manualtmp" 2>>"$LOG_FILE"; then
    if gpg --dearmor "$manualtmp" 2>>"$LOG_FILE"; then
      sudo_run mv "${manualtmp}.gpg" "$output"
      sudo_run chmod 644 "$output"
      rm -f "$manualtmp"
      log "${GREEN}Chave instalada pelo método 5${NC}"
      return 0
    fi
  fi

  handle_error "Falha ao instalar chave GPG de $url"
  return 1
}

# ===========================
# Instalação do PostgreSQL e repositório com validações
# ===========================
instalar_postgresql() {
  log "${YELLOW}Configurando repositório PostgreSQL...${NC}"
  sudo_run rm -f /etc/apt/sources.list.d/pgdg.list || true
  echo "deb https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list

  if ! corrigir_chave_gpg "https://www.postgresql.org/media/keys/ACCC4CF8.asc" "/usr/share/keyrings/postgresql.gpg"; then
    handle_error "Erro ao corrigir chave GPG PostgreSQL"
  fi

  sudo_run apt-get update >> "$LOG_FILE" 2>&1 || handle_error "apt update falhou após adicionar repositório PostgreSQL"

  # Verifica se PostgreSQL já está instalado
  if command -v psql &>/dev/null; then
    log "${GREEN}PostgreSQL já está instalado. Pulando instalação.${NC}"
  else
    log "${YELLOW}Instalando PostgreSQL...${NC}"
    sudo_run apt-get install -y postgresql postgresql-contrib >> "$LOG_FILE" 2>&1 || handle_error "Falha ao instalar PostgreSQL"
  fi

  # Validação pós instalação
  if ! command -v psql &>/dev/null; then
    handle_error "Comando psql não encontrado após instalação do PostgreSQL"
  else
    log "${GREEN}PostgreSQL instalado com sucesso.${NC}"
  fi
}

# ===========================
# Inicializa e valida o serviço PostgreSQL
# ===========================
iniciar_postgresql() {
  log "${YELLOW}Habilitando e iniciando serviço PostgreSQL...${NC}"
  sudo_run systemctl enable postgresql
  sudo_run systemctl start postgresql

  # Validação ativa
  if sudo systemctl is-active --quiet postgresql; then
    log "${GREEN}Serviço PostgreSQL ativo.${NC}"
  else
    handle_error "Serviço PostgreSQL não está ativo após tentativa de start"
  fi
}

# ===========================
# Instalação do pgAdmin 4 com repositório e validação
# ===========================
instalar_pgadmin() {
  log "${YELLOW}Configurando repositório pgAdmin 4...${NC}"
  sudo_run rm -f /etc/apt/sources.list.d/pgadmin4.list || true

  if ! corrigir_chave_gpg "https://www.pgadmin.org/static/packages_pgadmin_org.pub" "/usr/share/keyrings/pgadmin-keyring.gpg"; then
    handle_error "Erro ao corrigir chave GPG pgAdmin"
  fi

  echo "deb [signed-by=/usr/share/keyrings/pgadmin-keyring.gpg] https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/$(lsb_release -cs) pgadmin4 main" | sudo tee /etc/apt/sources.list.d/pgadmin4.list

  sudo_run apt-get update >> "$LOG_FILE" 2>&1 || handle_error "apt update falhou após adicionar repositório pgAdmin"

  # Verifica se pgAdmin já está instalado
  if dpkg -l pgadmin4-desktop &>/dev/null; then
    log "${GREEN}pgAdmin 4 já está instalado. Pulando instalação.${NC}"
  else
    log "${YELLOW}Instalando pgAdmin 4 desktop...${NC}"
    sudo_run apt-get install -y pgadmin4-desktop >> "$LOG_FILE" 2>&1 || handle_error "Falha ao instalar pgAdmin 4"
  fi

  log "${GREEN}pgAdmin 4 instalação concluída.${NC}"
}

# ===========================
# Limpeza e verificação de cache APT
# ===========================
limpar_cache() {
  log "${YELLOW}Limpando cache APT...${NC}"
  sudo_run apt-get autoclean >> "$LOG_FILE" 2>&1 || handle_error "Falha ao limpar cache APT"
}

# ===========================
# Verifica se sudo está disponível e funciona no início
# ===========================
verificar_sudo() {
  log "${YELLOW}Verificando permissão sudo...${NC}"
  if ! sudo -v; then
    handle_error "Usuário não tem permissão sudo válida ou sudo expirou"
    exit 1
  fi
  log "${GREEN}Permissão sudo confirmada.${NC}"
}

# ===========================
# Correção final dos repositórios para evitar duplicatas e conflitos
# ===========================
corrigir_repos_final() {
  log "${YELLOW}Iniciando correção final dos repositórios...${NC}"

  echo "[1/10] Removendo repositórios de versão anterior (jammy)..."
  sudo rm -f /etc/apt/sources.list.d/*jammy*
  sudo sed -i '/jammy/d' /etc/apt/sources.list

  echo "[2/10] Corrigindo fontes de repositório principais para versão correta (noble)..."
  sudo sed -i 's/jammy/noble/g' /etc/apt/sources.list

  echo "[3/10] Atualizando lista de pacotes..."
  sudo apt update

  echo "[4/10] Limpando cache de pacotes obsoletos..."
  sudo apt clean
  sudo apt autoclean

  echo "[5/10] Corrigindo pacotes quebrados automaticamente..."
  sudo dpkg --configure -a
  sudo apt --fix-broken install -y

  echo "[6/10] Forçando reinstalação de pacotes com dependências corrompidas..."
  sudo apt install --reinstall fonts-liberation2 libcurl4 libgs-common libgtk2.0-0 libcups2 libtirpc3 libparted2 ubuntu-advantage-tools -y

  echo "[7/10] Removendo pacotes conflitantes legados (se ainda presentes)..."
  sudo apt remove fonts-liberation libgs9-common libgail18 libext2fs2 libcurl4 libtirpc3 libgtk2.0-0 libparted2 libcups2 ubuntu-advantage-tools -y || true

  echo "[8/10] Atualizando o sistema com base limpa e coerente..."
  sudo apt update && sudo apt full-upgrade -y

  echo "[9/10] Limpando pacotes órfãos e dependências residuais..."
  sudo apt autoremove -y
  sudo apt autoclean

  echo "[10/10] Correção final concluída. Reinicie o sistema se necessário para aplicar mudanças."

  log "${GREEN}Correção final dos repositórios concluída.${NC}"
}

# ===========================
# Execução sequencial
# ===========================

log "${BLUE}Início da instalação robusta do PostgreSQL e pgAdmin 4${NC}"

verificar_sudo
check_network || exit 1
check_disk_space || exit 1
verificar_instalar_pacotes
backup_e_saneamento_repos
limpar_cache
instalar_postgresql
iniciar_postgresql
instalar_pgadmin
corrigir_repos_final

log "${GREEN}Instalação concluída. Verifique o arquivo de log para detalhes: ${LOG_FILE}${NC}"
