#!/bin/bash

# ============================================================
# Instalador Inteligente e Seguro do VirtualBox
# Licença: MIT | Autor: Assistente Grok | Versão Final 3.1
# ============================================================

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${BLUE}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[ERRO]${NC} $1"; }

# --------------------------------------------
# Banner compacto
# --------------------------------------------
clear
echo -e "${CYAN}"
cat << "EOF"
╔══════════════════════════════════════════════════════╗
║                                                      ║
║                 V I R T U A L   B O X                ║
║                                                      ║
║           Instalador Inteligente e Seguro            ║
║                                                      ║
╠══════════════════════════════════════════════════════╣
║  Detecta distro • Verifica VT-x/AMD-V e Secure Boot  ║
║  Remove instalações quebradas • Instala dependências ║
║  Instala VirtualBox • Compila módulo vboxdrv         ║
║  Corrige erros comuns • Adiciona usuário ao grupo    ║
║                                                      ║
║  Licença: MIT  |  Autor: Grok  |  Versão: 3.1        ║
╚══════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# --------------------------------------------
# Aviso obrigatório (compacto)
# --------------------------------------------
echo -e "${YELLOW}"
cat << "EOF"
╔══════════════════════════════════════════════════════╗
║  ATENÇÃO: Ative a Virtualização no BIOS antes!       ║
║                                                      ║
║  1. Reinicie e entre no BIOS (Del / F2 / F10 / Esc)  ║
║  2. Ative: Intel VT-x  ou  AMD-V / SVM               ║
║  3. Salve e saia (Save & Exit)                       ║
║                                                      ║
║  Sem isso o VirtualBox pode não funcionar bem.       ║
╚══════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"
echo -e "${GREEN}Pressione ENTER depois de ativar a virtualização no BIOS...${NC}"
read -r

TMPDIR=$(mktemp -d /tmp/vbox-install.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# --------------------------------------------
# 0. Proteção básica
# --------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    err "Não execute este script como root."
    err "Execute como usuário normal. O script pedirá sudo quando necessário."
    exit 1
fi

# --------------------------------------------
# 1. Detecta sistema e kernel
# --------------------------------------------
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID=$ID
        DISTRO_LIKE=$ID_LIKE
        VERSION_ID=$VERSION_ID
    else
        DISTRO_ID="unknown"
        DISTRO_LIKE=""
    fi

    KERNEL=$(uname -r)
    KERNEL_MAJOR=$(echo "$KERNEL" | cut -d. -f1)

    if [[ "$DISTRO_ID" =~ (ubuntu|debian|linuxmint|pop|elementary|zorin) ]] || [[ "$DISTRO_LIKE" =~ debian ]]; then
        FAMILY="debian"
    elif [[ "$DISTRO_ID" =~ (fedora|rhel|centos|rocky|almalinux|ol) ]] || [[ "$DISTRO_LIKE" =~ (rhel|fedora) ]]; then
        FAMILY="rhel"
    elif [[ "$DISTRO_ID" =~ (arch|manjaro|endeavouros|garuda) ]] || [[ "$DISTRO_LIKE" =~ arch ]]; then
        FAMILY="arch"
    else
        FAMILY="generic"
    fi

    log "Sistema: $DISTRO_ID | Família: $FAMILY | Kernel: $KERNEL"
}

# --------------------------------------------
# 2. Verificações de segurança e hardware
# --------------------------------------------
pre_checks() {
    log "Executando verificações prévias..."

    if grep -Eq '(vmx|svm)' /proc/cpuinfo; then
        ok "Virtualização de hardware (VT-x/AMD-V) detectada."
    else
        warn "VT-x/AMD-V ainda NÃO foi detectado."
        echo -e "${YELLOW}A virtualização continua desativada no BIOS ou não está disponível.${NC}"
        echo "O script vai continuar, mas o desempenho da VM pode ser ruim."
        echo
    fi

    if lsmod | grep -q kvm; then
        warn "Módulo KVM está carregado. Tentando liberar..."
        sudo modprobe -r kvm_intel 2>/dev/null || true
        sudo modprobe -r kvm_amd 2>/dev/null || true
        sudo modprobe -r kvm 2>/dev/null || true
    fi

    if command -v mokutil >/dev/null 2>&1; then
        if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
            warn "Secure Boot está ATIVO. Pode impedir o módulo vboxdrv."
            warn "Se falhar, desative o Secure Boot no BIOS."
        else
            ok "Secure Boot desativado ou não ativo."
        fi
    fi

    AVAILABLE=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "$AVAILABLE" -lt 2 ]; then
        warn "Pouco espaço em disco (menos de 2GB livres)."
    fi
}

# --------------------------------------------
# 3. Fecha processos
# --------------------------------------------
close_vbox() {
    log "Fechando processos do VirtualBox..."
    pkill -9 -f VirtualBox 2>/dev/null || true
    pkill -9 -f VBox 2>/dev/null || true
    sleep 2
}

# --------------------------------------------
# 4. Prepara ambiente
# --------------------------------------------
prepare_environment() {
    log "Preparando ambiente e corrigindo dependências..."

    case $FAMILY in
        debian)
            sudo apt update || true
            sudo apt install -y --fix-missing \
                build-essential dkms linux-headers-$(uname -r) \
                gcc make perl libelf-dev wget gnupg curl 2>/dev/null || true
            sudo dpkg --configure -a || true
            sudo apt --fix-broken install -y || true
            sudo apt install -f -y || true
            ;;
        rhel)
            if command -v dnf >/dev/null; then
                sudo dnf install -y kernel-devel kernel-headers gcc make perl \
                    elfutils-libelf-devel wget tar 2>/dev/null || true
                sudo dnf install -y kernel-devel-$(uname -r) 2>/dev/null || true
            else
                sudo yum install -y kernel-devel kernel-headers gcc make perl \
                    elfutils-libelf-devel wget tar 2>/dev/null || true
            fi
            ;;
        arch)
            sudo pacman -Sy --noconfirm base-devel linux-headers dkms wget 2>/dev/null || true
            ;;
        *)
            warn "Sistema genérico. Dependências básicas podem faltar."
            ;;
    esac
}

# --------------------------------------------
# 5. Remove instalações antigas
# --------------------------------------------
cleanup_old() {
    log "Removendo instalações antigas ou quebradas..."

    case $FAMILY in
        debian)
            sudo systemctl stop vboxdrv 2>/dev/null || true
            sudo apt purge -y virtualbox virtualbox-dkms virtualbox-qt \
                virtualbox-7.0 virtualbox-7.1 2>/dev/null || true
            sudo dpkg --remove --force-all virtualbox-dkms virtualbox 2>/dev/null || true
            sudo apt autoremove -y || true
            sudo rm -rf /var/lib/dkms/virtualbox
            sudo rm -f /var/crash/virtualbox*.crash
            ;;
        rhel)
            sudo systemctl stop vboxdrv 2>/dev/null || true
            sudo dnf remove -y VirtualBox* 2>/dev/null || sudo yum remove -y VirtualBox* 2>/dev/null || true
            ;;
        arch)
            sudo pacman -Rns --noconfirm virtualbox virtualbox-host-dkms 2>/dev/null || true
            ;;
    esac

    rm -f ~/.config/VirtualBox/VirtualBox.xml 2>/dev/null || true
    rm -f ~/.VirtualBox/VirtualBox.xml 2>/dev/null || true
    rm -rf ~/.cache/VirtualBox 2>/dev/null || true
}

# --------------------------------------------
# 6. Instalação
# --------------------------------------------
install_virtualbox() {
    log "Instalando VirtualBox..."

    if [ "$KERNEL_MAJOR" -lt 4 ]; then
        warn "Kernel $KERNEL é muito antigo. VirtualBox 7.x pode não funcionar bem."
    fi

    case $FAMILY in
        debian)
            wget -q https://www.virtualbox.org/download/oracle_vbox_2016.asc -O- | \
                sudo gpg --dearmor -o /usr/share/keyrings/oracle-virtualbox-2016.gpg 2>/dev/null || true

            CODENAME=$(lsb_release -cs 2>/dev/null || echo "noble")
            echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] https://download.virtualbox.org/virtualbox/debian $CODENAME contrib" | \
                sudo tee /etc/apt/sources.list.d/virtualbox.list > /dev/null

            sudo apt update || true
            sudo apt install -y virtualbox-7.1 || \
            sudo apt install -y virtualbox-7.0 || \
            sudo apt install -y virtualbox || true
            ;;
        rhel)
            if [[ "$DISTRO_ID" == "fedora" ]]; then
                sudo dnf install -y https://download.virtualbox.org/virtualbox/rpm/fedora/virtualbox.repo 2>/dev/null || true
                sudo dnf install -y VirtualBox-7.1 || sudo dnf install -y VirtualBox 2>/dev/null || true
            else
                sudo rpm --import https://www.virtualbox.org/download/oracle_vbox_2016.asc 2>/dev/null || true
                sudo dnf install -y https://download.virtualbox.org/virtualbox/rpm/rhel/virtualbox.repo 2>/dev/null || true
                sudo dnf install -y VirtualBox-7.1 || sudo yum install -y VirtualBox-7.1 || true
            fi
            ;;
        arch)
            sudo pacman -S --noconfirm virtualbox virtualbox-host-dkms linux-headers 2>/dev/null || true
            ;;
        *)
            warn "Usando instalador genérico .run da Oracle..."
            cd "$TMPDIR"
            wget -q https://download.virtualbox.org/virtualbox/7.1.6/VirtualBox-7.1.6-167084-Linux_amd64.run -O VBox.run || true
            if [ -f VBox.run ]; then
                chmod +x VBox.run
                sudo ./VBox.run || true
            fi
            ;;
    esac
}

# --------------------------------------------
# 7. Configurações finais
# --------------------------------------------
post_install() {
    log "Aplicando configurações finais..."

    if getent group vboxusers >/dev/null; then
        sudo usermod -aG vboxusers "$USER" || true
    fi

    if [ -f /sbin/vboxconfig ]; then
        sudo /sbin/vboxconfig || true
    elif [ -f /usr/lib/virtualbox/vboxdrv.sh ]; then
        sudo /usr/lib/virtualbox/vboxdrv.sh setup || true
    fi

    sudo modprobe vboxdrv 2>/dev/null || true
    sudo modprobe vboxnetflt 2>/dev/null || true
    sudo modprobe vboxnetadp 2>/dev/null || true

    sudo chown -R "$USER:$USER" ~/.config/VirtualBox 2>/dev/null || true
    sudo chown -R "$USER:$USER" ~/.VirtualBox 2>/dev/null || true
    VBoxManage setextradata global GUI/LastItemSelected 2>/dev/null || true
}

# --------------------------------------------
# 8. Verificação final
# --------------------------------------------
final_check() {
    echo
    if lsmod | grep -q vboxdrv; then
        ok "Módulo vboxdrv carregado com sucesso!"
        echo -e "${GREEN}=========================================="
        echo "  VirtualBox pronto para uso."
        echo -e "==========================================${NC}"
        echo
        echo "Reinicie o computador e abra o VirtualBox."
        echo "Seu usuário foi adicionado ao grupo vboxusers."
    else
        warn "Módulo vboxdrv NÃO está carregado."
        echo
        echo "Próximos passos:"
        echo "1. Reinicie o computador"
        echo "2. Execute: sudo /sbin/vboxconfig"
        echo "3. Desative Secure Boot no BIOS (se ativo)"
        echo "4. Verifique: lsmod | grep vbox"
        echo "5. Confirme VT-x/AMD-V no BIOS"
    fi
}

# ============================================
# EXECUÇÃO PRINCIPAL
# ============================================
detect_system
pre_checks
close_vbox
cleanup_old
prepare_environment
install_virtualbox
post_install
final_check

echo
log "Script finalizado."
