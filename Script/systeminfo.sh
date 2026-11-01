#!/usr/bin/env bash

# ============================================================
# LINUX SYSTEM DASHBOARD UI - SYSADMIN
# Shell : bash >= 4.x
# Kernel: Linux >= 3.10
# Read-only | Seguro | Diagnóstico rápido
# ============================================================

# ------------------ VALIDAÇÃO DE BASH ------------------
if (( BASH_VERSINFO[0] < 4 )); then
  echo -e "\e[31mERRO: Bash >= 4.0 é obrigatória.\e[0m"
  echo "Versão atual: $BASH_VERSION"
  exit 1
fi

# ------------------ CORES ------------------
RESET="\e[0m"
BOLD="\e[1m"
DIM="\e[2m"

C_TITLE="\e[38;5;39m"
C_LABEL="\e[38;5;75m"
C_VALUE="\e[38;5;114m"
C_WARN="\e[38;5;220m"
C_CRIT="\e[38;5;196m"
C_OK="\e[38;5;82m"
C_BOX="\e[38;5;240m"
C_SOFT="\e[38;5;245m"
C_HEAD="\e[38;5;250m"

# ------------------ FUNÇÕES UI ------------------
box_top()    { echo -e "${C_BOX}╔════════════════════════════════════════════════════╗${RESET}"; }
box_mid()    { echo -e "${C_BOX}╟────────────────────────────────────────────────────╢${RESET}"; }
box_soft()   { echo -e "${C_SOFT}╟────────────────────────────────────────────────────╢${RESET}"; }
box_bottom() { echo -e "${C_BOX}╚════════════════════════════════════════════════════╝${RESET}"; }

row() {
  printf "${C_BOX}║${RESET} ${C_LABEL}%-22s${RESET} ${C_VALUE}%-22s${RESET} ${C_BOX}║${RESET}\n" "$1" "$2"
}

header_row() {
  printf "${C_BOX}║${RESET} ${BOLD}${C_HEAD}%-22s${RESET} ${BOLD}${C_HEAD}%-22s${RESET} ${C_BOX}║${RESET}\n" "$1" "$2"
}

status_icon() {
  local val=$1 warn=$2 crit=$3
  if [ "$val" -ge "$crit" ]; then
    echo -e "${C_CRIT}🔴${RESET}"
  elif [ "$val" -ge "$warn" ]; then
    echo -e "${C_WARN}🟡${RESET}"
  else
    echo -e "${C_OK}🟢${RESET}"
  fi
}

to_gb() {
  awk "BEGIN {printf \"%.2f GB\", $1/1024/1024}"
}

# ------------------ HEADER ------------------
clear
HOST=$(hostname)
NOW=$(date "+%Y-%m-%d %H:%M:%S")

echo -e "${BOLD}${C_TITLE}"
echo "╔════════════════════════════════════════════════════╗"
echo "║        LINUX SYSTEM DASHBOARD  –  SYSADMIN        ║"
echo "╚════════════════════════════════════════════════════╝"
echo -e "${RESET}${DIM}Host: ${HOST}  |  Atualizado em: ${NOW}${RESET}"
echo -e "${DIM}Compatível: Kernel >= 3.10 | Bash >= 4.x${RESET}\n"

# ============================================================
# SISTEMA OPERACIONAL
# ============================================================
box_top
echo -e "${C_BOX}║${RESET} ${BOLD}${C_TITLE}🖥  SISTEMA OPERACIONAL${RESET}                          ${C_BOX}║${RESET}"
box_mid
header_row "CAMPO" "VALOR"
box_soft

OS_NAME=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
OS_VER=$(grep VERSION_ID /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')

row "Distribuição" "${OS_NAME:-N/A}"
row "Versão" "${OS_VER:-N/A}"

box_bottom
echo

# ============================================================
# KERNEL
# ============================================================
box_top
echo -e "${C_BOX}║${RESET} ${BOLD}${C_TITLE}🧠  KERNEL (CRÍTICO)${RESET}                           ${C_BOX}║${RESET}"
box_mid
header_row "ITEM" "VALOR"
box_soft

row "Kernel" "$(uname -r)"
row "Arquitetura" "$(uname -m)"

box_bottom
echo

# ============================================================
# AMBIENTE & RUNTIME
# ============================================================
box_top
echo -e "${C_BOX}║${RESET} ${BOLD}${C_TITLE}⚙️  AMBIENTE & RUNTIME (CRÍTICO)${RESET}               ${C_BOX}║${RESET}"
box_mid
header_row "ITEM" "VALOR"
box_soft

row "Shell (bash)" "$BASH_VERSION"

if pidof systemd >/dev/null 2>&1; then
  INIT_SYS="systemd"
elif [ -d /etc/init.d ]; then
  INIT_SYS="sysvinit"
else
  INIT_SYS="desconhecido"
fi
row "Init system" "$INIT_SYS"

if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
  FW="nftables ativo"
elif command -v iptables >/dev/null 2>&1 && iptables -L >/dev/null 2>&1; then
  FW="iptables ativo"
elif command -v ufw >/dev/null 2>&1 && ufw status | grep -q active; then
  FW="ufw ativo"
else
  FW="não detectado"
fi
row "Firewall" "$FW"

if command -v getenforce >/dev/null 2>&1; then
  SEC_MOD="SELinux $(getenforce)"
elif [ -d /sys/kernel/security/apparmor ]; then
  SEC_MOD="AppArmor ativo"
else
  SEC_MOD="não ativo"
fi
row "Segurança kernel" "$SEC_MOD"

VIRT=$(systemd-detect-virt 2>/dev/null)
row "Virtualização" "${VIRT:-Bare metal}"

row "Uptime" "$(uptime -p)"

TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)
row "Timezone" "${TZ:-N/A}"

box_bottom
echo

# ============================================================
# MEMÓRIA RAM
# ============================================================
box_top
echo -e "${C_BOX}║${RESET} ${BOLD}${C_TITLE}💾  MEMÓRIA RAM (CRÍTICO)${RESET}                     ${C_BOX}║${RESET}"
box_mid
header_row "TIPO" "VALOR"
box_soft

MEM_TOTAL_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_AVAIL_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
MEM_USED_KB=$((MEM_TOTAL_KB - MEM_AVAIL_KB))
MEM_USED_PCT=$((MEM_USED_KB * 100 / MEM_TOTAL_KB))

row "Total" "$(to_gb "$MEM_TOTAL_KB")"
row "Em uso" "$(to_gb "$MEM_USED_KB")"
row "Disponível" "$(to_gb "$MEM_AVAIL_KB")"

box_bottom
echo

# ============================================================
# HARDWARE
# ============================================================
box_top
echo -e "${C_BOX}║${RESET} ${BOLD}${C_TITLE}🔧  HARDWARE${RESET}                                 ${C_BOX}║${RESET}"
box_mid
header_row "COMPONENTE" "DESCRIÇÃO"
box_soft

row "Fabricante" "$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || echo N/A)"
row "Modelo" "$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo N/A)"

CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')
CPU_CORES=$(grep -c '^processor' /proc/cpuinfo)

row "CPU" "${CPU_MODEL:-N/A}"
row "Núcleos" "$CPU_CORES"

box_bottom
echo

# ============================================================
# ARMAZENAMENTO
# ============================================================
box_top
echo -e "${C_BOX}║${RESET} ${BOLD}${C_TITLE}📀  ARMAZENAMENTO (CRÍTICO)${RESET}                   ${C_BOX}║${RESET}"
box_mid
printf "${C_BOX}║${RESET} ${BOLD}${C_HEAD}%-12s %-8s %-8s %-8s %-8s${RESET} ${C_BOX}║${RESET}\n" \
"MONTE" "USO%" "TOTAL" "USADO" "LIVRE"
box_soft

df -h --output=target,pcent,size,used,avail 2>/dev/null | tail -n +2 | while read -r mount pct size used avail; do
  pct_num=${pct%\%}
  printf "${C_BOX}║${RESET} ${C_LABEL}%-12s${RESET} ${C_VALUE}%4s%%${RESET} ${C_SOFT}%-8s %-8s %-8s${RESET} ${C_BOX}║${RESET}\n" \
  "$mount" "$pct_num" "$size" "$used" "$avail"
done

box_bottom
echo

# ------------------ FOOTER ------------------
echo -e "${BOLD}${C_OK}✔ Dashboard carregado com sucesso.${RESET}"
echo -e "${DIM}Leitura otimizada para incidentes, auditoria e troubleshooting.${RESET}\n"
