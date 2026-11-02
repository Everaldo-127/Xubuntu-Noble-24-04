#!/bin/bash

################################################################################
# INSTALADOR CISCO PACKET TRACER - BLACKOPS DEFINITIVO                        #
#                                                                              #
# 💻 Este script automatiza o processo de instalação do Cisco Packet Tracer   #
# em sistemas baseados no Ubuntu. Ele lida com locks, dependências,           #
# repositórios temporários, e permite instalar um .deb baixado manualmente.   #
#                                                                              #
# ✅ Limpeza de locks e pacotes em hold                                        #
# ✅ Atualização e correção automática de pacotes                              #
# ✅ Gerenciamento de repositório Jammy temporário                             #
# ✅ Exibição de links para download do Packet Tracer                          #
# ✅ Instalação direta via arquivo .deb local                                  #
################################################################################

LOGFILE="/home/$USER/logs/packettracer_install.log"
mkdir -p "/home/$USER/logs"
exec > >(tee -a "$LOGFILE") 2>&1

log() {
  echo -e "[$(date +%H:%M:%S)] $1"
}

limpa_locks_holds() {
  log "🧹 LIMPANDO LOCKS E HOLDS"
  rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
  dpkg --configure -a
  log "🔓 Removendo pacotes em hold (se existirem)"
  for pkg in $(apt-mark showhold); do
    log "🔓 Removendo hold de: $pkg"
    apt-mark unhold "$pkg"
  done
}

atualiza_apt() {
  log "🔄 ATUALIZANDO APT"
  apt update -y || return 1
}

corrige_dependencias() {
  log "🧺 CORRIGINDO DEPENDÊNCIAS COM APTITUDE"
  if ! command -v aptitude &>/dev/null; then
    log "🚫 aptitude não encontrado. Instalando..."
    apt install -y aptitude || return 1
  else
    log "✅ aptitude já instalado"
  fi

  for tentativa in {1..3}; do
    log "🔁 Tentativa $tentativa de correção automática"
    aptitude -f -y install && return 0
    sleep 2
  done
  return 1
}

adiciona_repo_jammy() {
  if [[ -f /etc/apt/sources.list.d/jammy-temp.list ]]; then
    log "🧩 Repositório jammy temporário já existe, pulando adição."
    return 0
  fi
  log "🧩 ADICIONANDO REPO JAMMY TEMPORÁRIO"
  echo -e "deb http://archive.ubuntu.com/ubuntu jammy main universe multiverse" >/etc/apt/sources.list.d/jammy-temp.list
  echo -e "Package: *\nPin: release a=jammy\nPin-Priority: 1001" >/etc/apt/preferences.d/jammy-pin
  apt update || return 1
  return 0
}

remove_repo_jammy() {
  if [[ ! -f /etc/apt/sources.list.d/jammy-temp.list ]]; then
    log "🧽 Repositório jammy temporário não encontrado, pulando remoção."
    return
  fi
  log "🧽 REMOVENDO JAMMY TEMPORÁRIO"
  rm -f /etc/apt/sources.list.d/jammy-temp.list /etc/apt/preferences.d/jammy-pin
  apt update
}

restaurar_repositorio_noble() {
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

  echo "[10/10] Finalizado. Reinicie o sistema se necessário para aplicar mudanças."
}

exibir_link_gzip() {
  echo -e "\n\033[1;36m🔗 Link para download do pacote gzipado:\033[0m"
  echo -e "\033[1;37mhttps://drive.google.com/file/d/1y-mLAzwKHjbtLqJYRBaZq11Vf1Vjppra/view?usp=drive_link\033[0m"

  echo -e "\n\033[0;36m• Após o download, descompacte com o comando:\033[0m \033[1;33mgunzip nome_do_pacote.deb.gz\033[0m"
  echo -e "\033[0;36m• Após download, use a opção 3 para instalar com o arquivo .deb baixado.\033[0m"

  read -rp $'\nPressione ENTER para retornar ao menu...'
}

exibir_link_cisco() {
  echo -e "\n\033[1;36m🔗 Link para download oficial da Cisco NetAcad:\033[0m"
  echo -e "\033[1;37mLINK: https://www.netacad.com/resources/lab-downloads?courseLang=en-US\033[0m"

  echo -e "\n\033[0;36m• Após download, use a opção 3 para instalar com o arquivo .deb baixado.\033[0m"

  read -rp $'\nPressione ENTER para retornar ao menu...'
}

menu_final() {
  clear
  echo -e "\n\033[1;32m====== MENU de INSTALAÇÃO do Cisco PACKET TRACER ======\033[0m\n"

  echo -e "\033[1;34m1)\033[0m Baixar pacote gzipado do Packet Tracer (Google Drive) - \033[1;33mEXIBIR LINK\033[0m"
  echo -e "   \033[0;36m• Após download, descompacte com gunzip e use a opção 3 para instalar\033[0m\n"

  echo -e "\033[1;34m2)\033[0m Baixar .deb oficial no site Cisco NetAcad (login necessário) - \033[1;33mEXIBIR LINK\033[0m"
  echo -e "   \033[0;36m• Após download, use a opção 3 para instalar com o arquivo .deb baixado\033[0m\n"

  echo -e "\033[1;34m3)\033[0m Instalar Packet Tracer (.deb local):"
  echo -e "   \033[0;36m• Aponte o caminho completo do arquivo .deb já baixado\033[0m\n"

  echo -e "\033[1;34m4)\033[0m Restaurar repositórios para padrão (noble)\n"

  echo -e "\033[1;34m5)\033[0m Sair / finalizar a instalação.\n"

  read -rp "Escolha uma opção [1-5]: " opcao
  case $opcao in
    1)
      exibir_link_gzip
      menu_final
      ;;
    2)
      exibir_link_cisco
      menu_final
      ;;
    3)
      read -rp "Informe o caminho completo do arquivo .deb já extraído: " deb
      if [[ -f "$deb" ]]; then
        log "📦 Instalando o pacote .deb local: $deb"
        dpkg -i "$deb"
        if [[ $? -ne 0 ]]; then
          log "⚠️ Erro detectado na instalação via dpkg. Tentando corrigir dependências..."
          apt install -f -y --allow-downgrades
          if [[ $? -eq 0 ]]; then
            log "✅ Dependências corrigidas com sucesso. Tentando instalar o pacote novamente..."
            dpkg -i "$deb"
            if [[ $? -eq 0 ]]; then
              log "🚀 Packet Tracer instalado com sucesso após correção."
            else
              log "❌ Falha na instalação do pacote mesmo após correção."
            fi
          else
            log "❌ Falha ao corrigir dependências."
          fi
        else
          log "🚀 Packet Tracer instalado com sucesso."
        fi
      else
        log "❌ Arquivo .deb não encontrado."
      fi
      read -rp $'\nPressione ENTER para retornar ao menu...'
      menu_final
      ;;
    4)
      restaurar_repositorio_noble
      read -rp $'\nPressione ENTER para retornar ao menu...'
      menu_final
      ;;
    5)
      echo -e "\n🚪 Finalizando instalador. Até logo!\n"
      exit 0
      ;;
    *)
      echo -e "\033[1;31mOpção inválida.\033[0m"
      read -rp $'\nPressione ENTER para retornar ao menu...'
      menu_final
      ;;
  esac
}

### INÍCIO DO SCRIPT ###
log "🚀 INICIANDO INSTALADOR CISCO PACKET TRACER"
limpa_locks_holds
atualiza_apt || log "❌ Falha ao atualizar APT"
corrige_dependencias || log "❌ Falha ao corrigir dependências"

if [[ -f /etc/apt/sources.list.d/jammy-temp.list ]]; then
  log "🧩 Repositório jammy temporário já está presente, não adicionando novamente."
else
  adiciona_repo_jammy || { log "❌ [ERRO FATAL] Falha ao atualizar apt após adicionar jammy"; remove_repo_jammy; exit 1; }
fi

menu_final
remove_repo_jammy
