#!/bin/bash
# ==============================================================================
# Script: muda-ambientes.sh
# Descrição: Gerenciador independente de ambientes Linux
# Compatibilidade principal: Ubuntu/Xubuntu 24.04 LTS
# Shell: Bash 3.x+
# ==============================================================================

if [ "$EUID" -ne 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "[ERRO CRÍTICO] Este utilitário deve ser executado como root (sudo)." >&2
    exit 1
fi

LOG_FILE="/var/log/muda-ambientes.log"

cleanup_trap() {
    echo ""
    echo "[AVISO] Operação cancelada pelo usuário ou falha capturada." >&2
    rm -f /tmp/muda_lock 2>/dev/null
    exit 1
}
trap cleanup_trap INT TERM

if [ -f /tmp/muda_lock ]; then
    echo "[ERRO CRÍTICO] Já existe uma instância deste script em execução." >&2
    exit 1
fi

touch /tmp/muda_lock || {
    echo "[ERRO CRÍTICO] Não foi possível criar o arquivo de bloqueio." >&2
    exit 1
}

cleanup_normal() {
    rm -f /tmp/muda_lock 2>/dev/null
}
trap cleanup_normal EXIT

exec 3>&1 4>&2
exec 1> >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo " [INICIALIZAÇÃO] $(date)"
echo " Log de execução: $LOG_FILE"
echo "=================================================="

# ==============================================================================
# DETECÇÃO DO GERENCIADOR DE PACOTES
# ==============================================================================

detectar_gerenciador() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
        CMD_UPDATE="apt-get update"
        CMD_INSTALL="apt-get install -y --no-install-recommends"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MGR="pacman"
        CMD_UPDATE="pacman -Sy"
        CMD_INSTALL="pacman -S --noconfirm"
    else
        echo "[ERRO CRÍTICO] Nenhum gerenciador de pacotes suportado foi encontrado." >&2
        return 1
    fi

    echo "[AUDITORIA] Gerenciador validado: $PKG_MGR"
}

# ==============================================================================
# VERIFICAÇÃO E INSTALAÇÃO DE PACOTES
# ==============================================================================

verificar_ou_instalar() {
    local pacote="$1"
    local pacote_alternativo="${2:-}"

    if [ "$PKG_MGR" = "apt" ]; then
        if dpkg-query -W -f='${Status}' "$pacote" 2>/dev/null |
            grep -q "install ok installed"; then
            echo "[VERIFICAÇÃO] Componente '$pacote' já instalado."
            return 0
        fi
    elif [ "$PKG_MGR" = "pacman" ]; then
        if pacman -Qi "$pacote" >/dev/null 2>&1; then
            echo "[VERIFICAÇÃO] Componente '$pacote' já instalado."
            return 0
        fi
    fi

    echo "[DEPLOY] Instalando componente: $pacote..."

    $CMD_INSTALL "$pacote" >/dev/null 2>&1 || {
        echo "[AVISO] Falha ao instalar '$pacote'. Sincronizando repositórios..."

        $CMD_UPDATE >/dev/null 2>&1

        $CMD_INSTALL "$pacote" >/dev/null 2>&1 || {
            if [ -n "$pacote_alternativo" ]; then
                echo "[AVISO] Tentando pacote alternativo: $pacote_alternativo"

                $CMD_INSTALL "$pacote_alternativo" >/dev/null 2>&1 || {
                    echo "[AVISO] Pacote alternativo indisponível."
                }
            else
                echo "[AVISO] Pacote '$pacote' indisponível ou instalação malsucedida."
            fi
        }
    }
}

# ==============================================================================
# BACKUP PREVENTIVO
# ==============================================================================

backup_ambiente_alvo() {
    local ambiente="$1"
    local sessao="$2"
    local backup_base="/var/backups/muda-ambientes"
    local backup_dir
    local caminho
    local destino

    backup_dir="${backup_base}/${ambiente}-$(date +%Y%m%d-%H%M%S)"

    mkdir -p "$backup_dir" || {
        echo "[ERRO CRÍTICO] Não foi possível criar o diretório de backup."
        return 1
    }

    echo "[BACKUP] Preparando backup de $ambiente..."

    for caminho in \
        /etc/lightdm \
        /var/lib/AccountsService/users \
        "/usr/share/xsessions/$sessao"
    do
        if [ -e "$caminho" ] || [ -L "$caminho" ]; then
            destino="${backup_dir}${caminho}"

            mkdir -p "$(dirname "$destino")" || {
                echo "[ERRO CRÍTICO] Falha ao preparar backup de $caminho."
                return 1
            }

            cp -a "$caminho" "$destino" || {
                echo "[ERRO CRÍTICO] Falha ao copiar $caminho."
                return 1
            }
        fi
    done

    echo "[BACKUP] Concluído: $backup_dir"
    return 0
}

# ==============================================================================
# INSTALAÇÃO VALIDADA DE PACOTES CRÍTICOS
# ==============================================================================

instalar_pacotes_criticos() {
    if [ "$PKG_MGR" != "apt" ]; then
        echo "[ERRO] Esta rotina de instalação em lote requer APT."
        return 1
    fi

    echo "[DEPLOY] Atualizando índices dos repositórios..."

    apt-get update || {
        echo "[ERRO CRÍTICO] Não foi possível atualizar os repositórios."
        return 1
    }

    echo "[DEPLOY] Instalando componentes..."

    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends "$@" || {
        echo "[ERRO CRÍTICO] Falha na instalação dos componentes."
        return 1
    }

    echo "[DEPLOY] Instalação concluída."
    return 0
}

# ==============================================================================
# VALIDAÇÃO DE EXECUTÁVEIS
# ==============================================================================

validar_executaveis() {
    local executavel
    local falhas=0

    for executavel in "$@"; do
        if ! command -v "$executavel" >/dev/null 2>&1; then
            echo "[ERRO] Executável ausente: $executavel"
            falhas=1
        else
            echo "[OK] Executável encontrado: $executavel"
        fi
    done

    return "$falhas"
}

# ==============================================================================
# VERIFICAÇÃO DO PACOTE MATE SETTINGS DAEMON
# ==============================================================================

validar_pacote_mate_settings_daemon() {
    local pacote="mate-settings-daemon"

    echo "[VERIFICAÇÃO] Conferindo o pacote $pacote..."

    if dpkg-query -W -f='${Status}' "$pacote" 2>/dev/null |
        grep -q "install ok installed"; then
        echo "[OK] Pacote $pacote instalado."
        return 0
    fi

    echo "[AVISO] Pacote $pacote ausente. Tentando instalar..."

    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends "$pacote" || {
        echo "[ERRO] Não foi possível instalar $pacote."
        return 1
    }

    if ! dpkg-query -W -f='${Status}' "$pacote" 2>/dev/null |
        grep -q "install ok installed"; then
        echo "[ERRO] O pacote $pacote continua sem confirmação de instalação."
        return 1
    fi

    echo "[OK] Pacote $pacote instalado e validado."
    return 0
}

# ==============================================================================
# CONFIGURAÇÃO DO LIGHTDM
# ==============================================================================

configurar_display_manager_limpo() {
    local alvo_sessao="$1"

    echo "[CONFIGURAÇÃO] Configurando LightDM: $alvo_sessao"

    mkdir -p /etc/lightdm/lightdm.conf.d || return 1

    cat <<EOF > /etc/lightdm/lightdm.conf.d/10-greeter-sessions.conf
[Seat:*]
greeter-show-sessions=true
greeter-show-manual-login=false
allow-guest=false
user-session=$alvo_sessao
EOF

    if [ ! -f /etc/lightdm/lightdm-gtk-greeter.conf ]; then
        cat <<EOF > /etc/lightdm/lightdm-gtk-greeter.conf
[greeter]
indicators = ~host;~spacer;~clock;~spacer;~session;~power;~language
theme-name = Adwaita
icon-theme-name = gnome
font-name = Sans 10
hide-user-image = false
xfce-session = false
EOF
    fi

    if [ -d /var/lib/AccountsService/users ]; then
        for user_file in /var/lib/AccountsService/users/*; do
            [ -f "$user_file" ] || continue
            sed -i 's/^Session=.*/Session=/' "$user_file" 2>/dev/null || true
        done
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl set-default graphical.target >/dev/null 2>&1 || true
        systemctl unmask lightdm.service >/dev/null 2>&1 || true
        systemctl enable lightdm.service >/dev/null 2>&1 || true
    fi

    return 0
}

# ==============================================================================
# 1. LXQt
# ==============================================================================

executar_lxqt_independente() {
    echo "=================================================="
    echo " [EXECUÇÃO] ROTINA INDEPENDENTE: LXQT"
    echo "=================================================="

    detectar_gerenciador || return 1
    $CMD_UPDATE >/dev/null 2>&1

    if [ "$PKG_MGR" = "apt" ]; then
        verificar_ou_instalar "xserver-xorg"
        verificar_ou_instalar "xserver-xorg-core"
        verificar_ou_instalar "x11-xserver-utils"
        verificar_ou_instalar "libgl1-mesa-dri"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "openbox"
        verificar_ou_instalar "lxqt-core"
        verificar_ou_instalar "lxqt-session"
        verificar_ou_instalar "pcmanfm-qt"
        verificar_ou_instalar "lxqt-panel"
        verificar_ou_instalar "oxygen-icon-theme" "adwaita-icon-theme"

        mkdir -p /usr/share/xsessions

        cat <<EOF > /usr/share/xsessions/lxqt.desktop
[Desktop Entry]
Name=LXQt
Comment=LXQt Desktop Environment
Exec=startlxqt
TryExec=startlxqt
Type=Application
DesktopNames=LXQt
X-LightDM-DesktopName=LXQt
EOF

        if [ ! -f /usr/share/xsessions/lxqt-session.desktop ]; then
            ln -s /usr/share/xsessions/lxqt.desktop \
                /usr/share/xsessions/lxqt-session.desktop 2>/dev/null || true
        fi

        mkdir -p /etc/xdg/lxqt

        cat <<EOF > /etc/xdg/lxqt/session.conf
[General]
window_manager=openbox

[Session]
window_manager=openbox
EOF

        DEBIAN_FRONTEND=noninteractive dpkg-reconfigure lightdm >/dev/null 2>&1 || true
    else
        verificar_ou_instalar "xorg-server"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "openbox"
        verificar_ou_instalar "lxqt"
        verificar_ou_instalar "lxqt-session"
    fi

    configurar_display_manager_limpo "lxqt"
    echo "[SUCESSO] LXQt configurado."
}

# ==============================================================================
# 2. GNOME
# ==============================================================================

executar_gnome_independente() {
    echo "=================================================="
    echo " [EXECUÇÃO] ROTINA INDEPENDENTE: GNOME"
    echo "=================================================="

    detectar_gerenciador || return 1
    $CMD_UPDATE >/dev/null 2>&1

    if [ "$PKG_MGR" = "apt" ]; then
        verificar_ou_instalar "xserver-xorg"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "gnome-session"
        verificar_ou_instalar "gnome-shell"
        verificar_ou_instalar "gnome-terminal"
        verificar_ou_instalar "nautilus"
        verificar_ou_instalar "dbus-x11"

        mkdir -p /usr/share/xsessions
        rm -f /usr/share/xsessions/gnome-xorg.desktop 2>/dev/null || true

        cat <<EOF > /usr/share/xsessions/gnome.desktop
[Desktop Entry]
Name=GNOME
Comment=Esta sessão inicia o GNOME via X11
Exec=env GNOME_SHELL_SESSION_MODE=classic gnome-session --session=gnome
TryExec=gnome-shell
Type=Application
DesktopNames=GNOME
EOF
    else
        verificar_ou_instalar "xorg-server"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "gnome"
        verificar_ou_instalar "gnome-extra"
    fi

    configurar_display_manager_limpo "gnome"
    echo "[SUCESSO] GNOME configurado."
}

# ==============================================================================
# 3. KDE PLASMA
# ==============================================================================

executar_kde_independente() {
    echo "=================================================="
    echo " [EXECUÇÃO] ROTINA REVISADA: KDE PLASMA"
    echo "=================================================="

    detectar_gerenciador || return 1

    if [ "$PKG_MGR" = "apt" ]; then
        if [ ! -r /etc/os-release ]; then
            echo "[ERRO] Não foi possível identificar o sistema."
            return 1
        fi

        . /etc/os-release

        if [ "${ID:-}" != "ubuntu" ] ||
            [ "${VERSION_ID:-}" != "24.04" ]; then
            echo "[ERRO] Esta rotina requer Ubuntu 24.04 LTS."
            echo "[INFO] Sistema: ${PRETTY_NAME:-desconhecido}"
            return 1
        fi

        backup_ambiente_alvo "kde" "plasma.desktop" || return 1

        instalar_pacotes_criticos \
            xserver-xorg \
            lightdm \
            lightdm-gtk-greeter \
            kde-plasma-desktop \
            plasma-workspace \
            plasma-desktop \
            kwin-x11 \
            konsole \
            dolphin || return 1

        DEBIAN_FRONTEND=noninteractive \
            apt-get install -y --reinstall --no-install-recommends \
            kwin-x11 plasma-workspace || {
            echo "[ERRO] Falha ao reparar os componentes do KDE."
            return 1
        }

        validar_executaveis startplasma-x11 kwin_x11 || return 1

        if [ ! -f /usr/share/xsessions/plasma.desktop ]; then
            echo "[ERRO] Entrada oficial plasma.desktop não encontrada."
            return 1
        fi

        if ! grep -q 'Exec=.*startplasma-x11' \
            /usr/share/xsessions/plasma.desktop; then
            echo "[ERRO] Entrada oficial da sessão KDE inesperada."
            return 1
        fi
    else
        echo "[AVISO] Mantendo o fluxo original de instalação KDE no Pacman."
        verificar_ou_instalar "xorg-server"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "plasma"
        verificar_ou_instalar "konsole"
    fi

    configurar_display_manager_limpo "plasma" || return 1

    echo "[SUCESSO] KDE Plasma instalado e validado."
}

# ==============================================================================
# 4. Cinnamon
# ==============================================================================

executar_cinnamon_independente() {
    echo "=================================================="
    echo " [EXECUÇÃO] ROTINA INDEPENDENTE: CINNAMON"
    echo "=================================================="

    detectar_gerenciador || return 1
    $CMD_UPDATE >/dev/null 2>&1

    if [ "$PKG_MGR" = "apt" ]; then
        verificar_ou_instalar "xserver-xorg"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "cinnamon"
        verificar_ou_instalar "gnome-terminal"
        verificar_ou_instalar "nemo"

        mkdir -p /usr/share/xsessions

        cat <<EOF > /usr/share/xsessions/cinnamon.desktop
[Desktop Entry]
Name=Cinnamon
Comment=This session logs you into Cinnamon
Exec=cinnamon-session
TryExec=cinnamon
Type=Application
DesktopNames=Cinnamon
EOF
    else
        verificar_ou_instalar "xorg-server"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "cinnamon"
    fi

    configurar_display_manager_limpo "cinnamon"
    echo "[SUCESSO] Cinnamon configurado."
}

# ==============================================================================
# 5. XFCE
# ==============================================================================

executar_xfce_independente() {
    echo "=================================================="
    echo " [EXECUÇÃO] ROTINA INDEPENDENTE: XFCE"
    echo "=================================================="

    detectar_gerenciador || return 1
    $CMD_UPDATE >/dev/null 2>&1

    if [ "$PKG_MGR" = "apt" ]; then
        verificar_ou_instalar "xserver-xorg"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "xfwm4"
        verificar_ou_instalar "xfce4-session"
        verificar_ou_instalar "xfce4-panel"
        verificar_ou_instalar "xfce4-terminal"
        verificar_ou_instalar "thunar"

        mkdir -p /usr/share/xsessions
        rm -f /usr/share/xsessions/xfce4.desktop 2>/dev/null || true

        cat <<EOF > /usr/share/xsessions/xfce.desktop
[Desktop Entry]
Name=XFCE
Comment=Use este ambiente para iniciar o XFCE Session
Exec=xfce4-session
TryExec=xfce4-session
Type=Application
DesktopNames=XFCE
EOF
    else
        verificar_ou_instalar "xorg-server"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "xfce4"
        verificar_ou_instalar "xfce4-goodies"

        mkdir -p /usr/share/xsessions

        cat <<EOF > /usr/share/xsessions/xfce.desktop
[Desktop Entry]
Name=XFCE
Comment=Use este ambiente para iniciar o XFCE Session
Exec=xfce4-session
TryExec=xfce4-session
Type=Application
DesktopNames=XFCE
EOF
    fi

    configurar_display_manager_limpo "xfce"
    echo "[SUCESSO] XFCE configurado."
}

# ==============================================================================
# 6. MATE
# Correção: validação do pacote mate-settings-daemon sem falso erro de PATH.
# ==============================================================================

executar_mate_independente() {
    echo "=================================================="
    echo " [EXECUÇÃO] ROTINA REVISADA: MATE"
    echo "=================================================="

    detectar_gerenciador || return 1

    if [ "$PKG_MGR" != "apt" ]; then
        echo "[ERRO] Esta rotina corrigida requer APT."
        return 1
    fi

    if [ ! -r /etc/os-release ]; then
        echo "[ERRO] Não foi possível identificar o sistema."
        return 1
    fi

    . /etc/os-release

    if [ "${ID:-}" != "ubuntu" ] ||
        [ "${VERSION_ID:-}" != "24.04" ]; then
        echo "[ERRO] Esta rotina requer Ubuntu 24.04 LTS."
        echo "[INFO] Sistema: ${PRETTY_NAME:-desconhecido}"
        return 1
    fi

    # Backup preventivo antes de instalar ou alterar configurações.
    backup_ambiente_alvo "mate" "mate.desktop" || return 1

    # Instalação dos componentes oficiais e dependências de indicadores.
    instalar_pacotes_criticos \
        xserver-xorg \
        lightdm \
        lightdm-gtk-greeter \
        dbus-x11 \
        gvfs-backends \
        mate-desktop-environment \
        mate-desktop-environment-core \
        mate-session-manager \
        mate-settings-daemon \
        mate-panel \
        mate-control-center \
        mate-terminal \
        caja \
        marco \
        mate-notification-daemon \
        mate-polkit \
        mate-applets \
        mate-applet-brisk-menu \
        mate-indicator-applet \
        ayatana-indicator-common \
        ayatana-indicator-application \
        mate-power-manager \
        mate-screensaver \
        mate-system-monitor \
        mate-utils \
        mate-calc \
        pluma \
        atril \
        engrampa \
        eom || return 1

    # Verifica os pacotes responsáveis pelos indicadores.
    echo "[VERIFICAÇÃO] Conferindo os componentes de indicadores..."

    local pacote

    for pacote in \
        mate-indicator-applet \
        ayatana-indicator-common \
        ayatana-indicator-application
    do
        if ! dpkg-query -W -f='${Status}' "$pacote" 2>/dev/null |
            grep -q "install ok installed"; then
            echo "[ERRO] Pacote de indicadores ausente: $pacote"
            echo "[ERRO] A configuração do LightDM não será alterada."
            return 1
        fi

        echo "[OK] Pacote instalado: $pacote"
    done

    # Verifica o pacote do serviço de configurações do MATE.
    # Não exige que mate-settings-daemon esteja no PATH.
    validar_pacote_mate_settings_daemon || return 1

    # Valida os executáveis essenciais da sessão.
    validar_executaveis \
        mate-session \
        marco \
        mate-panel \
        caja || return 1

    # Preserva a entrada oficial da sessão MATE.
    if [ ! -f /usr/share/xsessions/mate.desktop ]; then
        echo "[ERRO] Entrada oficial da sessão MATE não encontrada."
        return 1
    fi

    if ! grep -q 'Exec=.*mate-session' /usr/share/xsessions/mate.desktop; then
        echo "[ERRO] Entrada oficial da sessão MATE inválida."
        return 1
    fi

    configurar_display_manager_limpo "mate" || return 1

    echo "=================================================="
    echo " [SUCESSO] MATE CONFIGURADO"
    echo "=================================================="
    echo "[OK] Pacotes de indicadores verificados."
    echo "[OK] Pacote mate-settings-daemon validado."
    echo "[OK] Componentes essenciais da sessão verificados."
    echo "[OK] Entrada oficial do MATE preservada."
    echo "[OK] LightDM configurado."
    echo "[INFO] Reinicie o sistema para testar a sessão."
    echo "[AVISO] Se o problema persistir, será necessário verificar os logs da sessão."
}

# ==============================================================================
# 7. REBOOT
# ==============================================================================

executar_reboot() {
    echo "[REBOOT] Sincronizando dados em disco e reiniciando em 3 segundos..."
    sync
    sleep 3
    reboot
}

# ==============================================================================
# MENU PRINCIPAL
# ==============================================================================

while true; do
    echo ""
    echo "=================================================="
    echo "       GERENCIADOR SÊNIOR DE AMBIENTES - UNIX"
    echo "=================================================="
    echo "1 - Trocar para LXQt"
    echo "2 - Trocar para GNOME"
    echo "3 - Trocar para KDE Plasma"
    echo "4 - Trocar para Cinnamon"
    echo "5 - Trocar para XFCE"
    echo "6 - Trocar para MATE"
    echo "7 - Reboot do Sistema"
    echo "8 - Sair"
    echo "=================================================="

    printf "Selecione a opção desejada [1-8]: "
    read opcao

    case "$opcao" in
        1)
            executar_lxqt_independente
            ;;
        2)
            executar_gnome_independente
            ;;
        3)
            executar_kde_independente
            ;;
        4)
            executar_cinnamon_independente
            ;;
        5)
            executar_xfce_independente
            ;;
        6)
            executar_mate_independente
            ;;
        7)
            executar_reboot
            ;;
        8)
            echo "[ENCERRANDO] Até logo!"
            exit 0
            ;;
        *)
            echo "[ERRO] Opção inválida! Digite um número entre 1 e 8."
            ;;
    esac
done
