#!/usr/bin/env bash
# =============================================================================
# WIFI-RECOVERY-MENU v5.0
#
# Plataformas suportadas (8 famílias, 25+ distribuições):
#   1 debian    : Debian, Ubuntu (LTS), Linux Mint, Pop!_OS, Zorin, Kali, Raspbian
#   2 fedora    : Fedora, Nobara
#   3 rhel      : RHEL, Rocky, AlmaLinux, Oracle Linux, CentOS (Stream), Amazon Linux
#   4 suse      : SLES, SLED, openSUSE Leap/Tumbleweed
#   5 arch      : Arch, Manjaro, EndeavourOS, Garuda, Artix, CachyOS
#   6 slackware : Slackware, Salix
#   7 alpine    : Alpine, postmarketOS
#   8 void      : Void Linux
#
# Gerenciadores de serviço: systemd, OpenRC, runit, rc.d (Slackware).
#
# Novidades da v5.0 (sobre a v4.2):
#   - Cache separado: packages/wifi, packages/drivers, packages/xfce
#   - Opção 2 detecta o hardware Wi-Fi e baixa firmware/módulos do driver correto
#     e grava um manifesto (wifi-hw.env) usado pela opção 4
#   - Opção 4 reinstala Wi-Fi + drivers/firmware/módulos do cache, carrega os
#     módulos, verifica firmware e só então restaura as configurações
#   - Opção 8 abre a sessão gráfica XFCE
#   - Correção: restauração com "cp -a dir dir_existente" criava diretório
#     aninhado (/etc/NetworkManager/etc__NetworkManager). Agora copia o conteúdo.
#   - Correção: "source /etc/os-release" sobrescrevia a variável VERSION.
#   - Correção: não inicia systemd-networkd quando o NetworkManager existe.
#   - Snapshot automático das configurações antes de restaurar/rollback.
# =============================================================================

set -uo pipefail
umask 077

SCRIPT_VERSION="5.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${WIFI_RECOVERY_CACHE:-$SCRIPT_DIR/wifi-recovery-cache}"
PKG_ROOT="$CACHE_DIR/packages"
PKG_WIFI="$PKG_ROOT/wifi"
PKG_DRV="$PKG_ROOT/drivers"
PKG_XFCE="$PKG_ROOT/xfce"
BACKUP_ROOT="$CACHE_DIR/backups"
LOG_DIR="$CACHE_DIR/logs"
MANIFEST="$CACHE_DIR/wifi-hw.env"
FW_LIST="$CACHE_DIR/wifi-firmware.list"
LOG_FILE="$LOG_DIR/menu-$(date +%Y%m%d-%H%M%S).log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

FAMILY=""; INIT="unknown"
DISTRO_ID=""; DISTRO_LIKE=""; DISTRO_VER=""; DISTRO_VER_MAJOR=""; PRETTY=""
WIFI_VENDORS=""; WIFI_MODULES=""
MF_KERNEL=""; MF_FAMILY=""; MF_VENDORS=""; MF_MODULES=""
MF_WIFI_PKGS=""; MF_DRV_PKGS=""; MF_XFCE_PKGS=""
RESTORED_COUNT=0

# -----------------------------------------------------------------------------
# Utilidades
# -----------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || true; }
info() { echo -e "${GREEN}[OK]${NC} $*"; log "OK: $*"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $*"; log "AVISO: $*"; }
err()  { echo -e "${RED}[ERRO]${NC} $*"; log "ERRO: $*"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
stamp() { date +%Y%m%d-%H%M%S; }

# ask "texto" [s|n]  -> retorna 0 para sim. O segundo argumento é o padrão.
ask() {
    local def="${2:-n}" hint ans
    if [[ "$def" == "s" ]]; then hint="(S/n)"; else hint="(s/N)"; fi
    read -r -p "$1 $hint: " ans
    ans="${ans:-$def}"
    [[ "$ans" =~ ^[SsYy]$ ]]
}

uniq_words() { echo "$*" | tr -s ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ' | sed 's/ $//'; }

usage() {
    cat <<EOF
WIFI RECOVERY MENU v$SCRIPT_VERSION

Uso: sudo bash $(basename "$0")        (em rede com proxy: sudo -E bash ...)

Famílias suportadas: debian, fedora, rhel, suse, arch, slackware, alpine, void
Variável opcional:   WIFI_RECOVERY_CACHE=/caminho  (muda o local do cache)

Notas para ambientes corporativos:
  - Os downloads usam o próprio gerenciador de pacotes (apt/dnf/yum/zypper/...),
    portanto funcionam com mirrors internos, Satellite, SMT/RMT e proxies.
  - RHEL/Rocky/Alma/Oracle: o XFCE vem do EPEL (o script oferece habilitá-lo).
  - SLES/SLED: o XFCE vem do SUSE Package Hub (comunitário, sem suporte SUSE).
  - Com Secure Boot, módulos de terceiros não assinados não serão carregados.
EOF
}

init_dirs() {
    mkdir -p "$PKG_WIFI" "$PKG_DRV" "$PKG_XFCE" "$BACKUP_ROOT" "$LOG_DIR" || {
        echo "Não foi possível criar $CACHE_DIR"; exit 1
    }
    chmod 700 "$CACHE_DIR" "$LOG_DIR" "$BACKUP_ROOT" 2>/dev/null || true
}

check_root() {
    (( EUID == 0 )) || { echo "Execute com sudo: sudo bash \"$0\""; exit 1; }
}

# -----------------------------------------------------------------------------
# Detecção de distribuição, família e init
# -----------------------------------------------------------------------------
detect_distro() {
    DISTRO_ID="desconhecida"; DISTRO_LIKE=""; PRETTY="desconhecida"; DISTRO_VER=""
    if [[ -r /etc/os-release ]]; then
        # Subshell: evita sobrescrever variáveis do script (ex.: VERSION)
        DISTRO_ID=$(. /etc/os-release; echo "${ID:-desconhecida}")
        DISTRO_LIKE=$(. /etc/os-release; echo "${ID_LIKE:-}")
        PRETTY=$(. /etc/os-release; echo "${PRETTY_NAME:-${ID:-desconhecida}}")
        DISTRO_VER=$(. /etc/os-release; echo "${VERSION_ID:-}")
    elif [[ -r /etc/slackware-version ]]; then
        DISTRO_ID="slackware"; PRETTY="$(cat /etc/slackware-version)"
    fi
    DISTRO_VER_MAJOR="${DISTRO_VER%%.*}"

    FAMILY=""
    case "$DISTRO_ID" in
        ubuntu|debian|linuxmint|pop|zorin|kali|raspbian|elementary|neon|parrot|mx) FAMILY="debian" ;;
        fedora|nobara) FAMILY="fedora" ;;
        rhel|centos|rocky|almalinux|ol|amzn|scientific|eurolinux|cloudlinux) FAMILY="rhel" ;;
        sles|sled|sles_sap|opensuse*|suse) FAMILY="suse" ;;
        arch|manjaro|endeavouros|garuda|artix|cachyos|arcolinux) FAMILY="arch" ;;
        slackware|salix|zenwalk) FAMILY="slackware" ;;
        alpine|postmarketos) FAMILY="alpine" ;;
        void) FAMILY="void" ;;
    esac

    if [[ -z "$FAMILY" ]]; then
        local tok
        for tok in $DISTRO_LIKE; do
            case "$tok" in
                debian|ubuntu) FAMILY="debian" ;;
                rhel|centos) FAMILY="rhel" ;;
                fedora) FAMILY="fedora" ;;
                suse|opensuse*) FAMILY="suse" ;;
                arch) FAMILY="arch" ;;
                slackware) FAMILY="slackware" ;;
                alpine) FAMILY="alpine" ;;
            esac
            [[ -n "$FAMILY" ]] && break
        done
    fi

    if [[ -z "$FAMILY" ]]; then
        if   has_cmd apt-get;       then FAMILY="debian"
        elif has_cmd dnf;           then FAMILY="rhel"
        elif has_cmd yum;           then FAMILY="rhel"
        elif has_cmd zypper;        then FAMILY="suse"
        elif has_cmd pacman;        then FAMILY="arch"
        elif has_cmd apk;           then FAMILY="alpine"
        elif has_cmd xbps-install;  then FAMILY="void"
        elif has_cmd installpkg;    then FAMILY="slackware"
        else
            echo "Distribuição não suportada (ID=$DISTRO_ID, ID_LIKE=$DISTRO_LIKE)."
            exit 1
        fi
    fi
}

detect_init() {
    if   [[ -d /run/systemd/system ]];          then INIT="systemd"
    elif has_cmd rc-service;                    then INIT="openrc"
    elif has_cmd sv && [[ -d /etc/sv ]];        then INIT="runit"
    elif [[ -f /etc/rc.d/rc.M ]];               then INIT="slackrc"
    else INIT="unknown"; fi
}

ubuntu_like() { [[ "$DISTRO_ID" == "ubuntu" || " $DISTRO_LIKE " == *" ubuntu "* ]]; }
rpm_pm() { if has_cmd dnf; then echo dnf; else echo yum; fi; }

# -----------------------------------------------------------------------------
# Abstração de serviços (systemd / OpenRC / runit / rc.d)
# Nomes lógicos: nm, wpa, dbus, dm, networkd
# -----------------------------------------------------------------------------
svc_proc() {
    case "$1" in
        nm) echo NetworkManager ;; wpa) echo wpa_supplicant ;;
        dbus) echo dbus-daemon ;; dm) echo lightdm ;; *) echo "$1" ;;
    esac
}

svc_name() {
    case "$INIT:$1" in
        openrc:nm)    echo networkmanager ;;
        slackrc:nm)   echo rc.networkmanager ;;
        slackrc:wpa)  echo rc.wpa_supplicant ;;
        slackrc:dbus) echo rc.messagebus ;;
        slackrc:dm)   echo "" ;;
        systemd:networkd) echo systemd-networkd ;;
        *:nm)         echo NetworkManager ;;
        *:wpa)        echo wpa_supplicant ;;
        *:dbus)       echo dbus ;;
        *:dm)         echo lightdm ;;
        *)            echo "" ;;
    esac
}

svc_exists() {
    local n; n=$(svc_name "$1"); [[ -n "$n" ]] || return 1
    case "$INIT" in
        systemd) systemctl cat "${n}.service" >/dev/null 2>&1 ;;
        openrc)  [[ -e "/etc/init.d/$n" ]] ;;
        runit)   [[ -d "/etc/sv/$n" ]] ;;
        slackrc) [[ -f "/etc/rc.d/$n" ]] ;;
        *)       return 1 ;;
    esac
}

svc_active() {
    local n; n=$(svc_name "$1"); [[ -n "$n" ]] || return 1
    case "$INIT" in
        systemd) systemctl is-active --quiet "$n" 2>/dev/null ;;
        openrc)  rc-service "$n" status >/dev/null 2>&1 ;;
        runit)   sv status "$n" 2>/dev/null | grep -q '^run:' ;;
        *)       pgrep -x "$(svc_proc "$1")" >/dev/null 2>&1 ;;
    esac
}

svc_start() {
    local n; n=$(svc_name "$1"); [[ -n "$n" ]] || return 1
    case "$INIT" in
        systemd) systemctl start "$n" 2>>"$LOG_FILE" ;;
        openrc)  rc-service "$n" start >>"$LOG_FILE" 2>&1 ;;
        runit)   [[ -e "/var/service/$n" ]] || ln -s "/etc/sv/$n" /var/service/ 2>>"$LOG_FILE"
                 sleep 3; sv up "$n" >>"$LOG_FILE" 2>&1 ;;
        slackrc) chmod +x "/etc/rc.d/$n" 2>/dev/null; "/etc/rc.d/$n" start >>"$LOG_FILE" 2>&1 ;;
        *)       return 1 ;;
    esac
}

svc_stop() {
    local n; n=$(svc_name "$1"); [[ -n "$n" ]] || return 1
    case "$INIT" in
        systemd) systemctl stop "$n" 2>>"$LOG_FILE" ;;
        openrc)  rc-service "$n" stop >>"$LOG_FILE" 2>&1 ;;
        runit)   sv down "$n" >>"$LOG_FILE" 2>&1 ;;
        slackrc) [[ -x "/etc/rc.d/$n" ]] && "/etc/rc.d/$n" stop >>"$LOG_FILE" 2>&1 ;;
        *)       return 1 ;;
    esac
}

svc_restart() {
    local n; n=$(svc_name "$1"); [[ -n "$n" ]] || return 1
    case "$INIT" in
        systemd) systemctl restart "$n" 2>>"$LOG_FILE" ;;
        openrc)  rc-service "$n" restart >>"$LOG_FILE" 2>&1 ;;
        runit)   sv restart "$n" >>"$LOG_FILE" 2>&1 ;;
        slackrc) chmod +x "/etc/rc.d/$n" 2>/dev/null; "/etc/rc.d/$n" restart >>"$LOG_FILE" 2>&1 ;;
        *)       return 1 ;;
    esac
}

svc_enable() {
    local n; n=$(svc_name "$1"); [[ -n "$n" ]] || return 1
    case "$INIT" in
        systemd) systemctl enable "$n" 2>>"$LOG_FILE" ;;
        openrc)  rc-update add "$n" default >>"$LOG_FILE" 2>&1 ;;
        runit)   [[ -e "/var/service/$n" ]] || ln -s "/etc/sv/$n" /var/service/ ;;
        slackrc) chmod +x "/etc/rc.d/$n" ;;
        *)       return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Listas de pacotes por família
#   Itens especiais: "@grupo" (dnf/yum) e "pattern:nome" (zypper)
# -----------------------------------------------------------------------------
get_wifi_pkgs() {
    case "$FAMILY" in
        debian)    echo "network-manager wpasupplicant rfkill iw wireless-regdb" ;;
        fedora)    echo "NetworkManager NetworkManager-wifi wpa_supplicant iw rfkill wireless-regdb" ;;
        rhel)      echo "NetworkManager NetworkManager-wifi wpa_supplicant iw wireless-regdb" ;;
        suse)      echo "NetworkManager wpa_supplicant iw wireless-regdb" ;;
        arch)      echo "networkmanager wpa_supplicant iw wireless-regdb" ;;
        slackware) echo "NetworkManager wpa_supplicant iw wireless-tools" ;;
        alpine)    echo "networkmanager networkmanager-wifi networkmanager-openrc wpa_supplicant wpa_supplicant-openrc iw wireless-regdb dbus dbus-openrc rfkill" ;;
        void)      echo "NetworkManager wpa_supplicant iw wireless-regdb dbus" ;;
    esac
}

# Drivers, firmware e módulos de kernel. Depende de WIFI_VENDORS (detect_wifi_hw).
get_driver_pkgs() {
    local v out="" vendors="${WIFI_VENDORS:-}"
    case "$FAMILY" in
        debian)
            if ubuntu_like; then
                out="linux-firmware linux-modules-extra-$(uname -r)"
            else
                [[ -n "$vendors" ]] || vendors="intel realtek atheros mediatek broadcom"
                for v in $vendors; do
                    case "$v" in
                        intel)             out+=" firmware-iwlwifi" ;;
                        realtek)           out+=" firmware-realtek" ;;
                        atheros|qualcomm)  out+=" firmware-atheros" ;;
                        mediatek)          out+=" firmware-misc-nonfree" ;;
                        broadcom)          out+=" firmware-brcm80211" ;;
                    esac
                done
            fi ;;
        fedora|rhel) out="linux-firmware kernel-modules-extra" ;;
        suse)        out="kernel-firmware kernel-default-extra" ;;
        arch)        out="linux-firmware" ;;
        slackware)   out="kernel-firmware" ;;
        alpine)
            if [[ -z "$vendors" ]]; then out="linux-firmware"; else
                for v in $vendors; do
                    case "$v" in
                        intel)    out+=" linux-firmware-intel" ;;
                        realtek)  out+=" linux-firmware-rtlwifi linux-firmware-rtw88 linux-firmware-rtw89" ;;
                        atheros)  out+=" linux-firmware-ath9k_htc linux-firmware-ath10k" ;;
                        qualcomm) out+=" linux-firmware-ath11k linux-firmware-ath12k" ;;
                        mediatek) out+=" linux-firmware-mediatek" ;;
                        broadcom) out+=" linux-firmware-brcm" ;;
                    esac
                done
            fi ;;
        void)
            out="linux-firmware-network linux-firmware-intel"
            [[ " $vendors " == *" broadcom "* ]] && out+=" linux-firmware-broadcom" ;;
    esac
    uniq_words "$out"
}

get_xfce_pkgs() {
    case "$FAMILY" in
        debian)    echo "xfce4 xfce4-goodies lightdm lightdm-gtk-greeter xserver-xorg xinit dbus-x11" ;;
        fedora)    echo "@xfce-desktop-environment lightdm xorg-x11-xinit" ;;
        rhel)      echo "@xfce-desktop @Xfce lightdm lightdm-gtk xorg-x11-xinit xorg-x11-server-Xorg" ;;
        suse)      echo "pattern:xfce lightdm lightdm-gtk-greeter xinit" ;;
        arch)      echo "xfce4 xorg-server xorg-xinit lightdm lightdm-gtk-greeter" ;;
        slackware) echo "xfce" ;;
        alpine)    echo "xfce4 xfce4-terminal lightdm lightdm-openrc lightdm-gtk-greeter xorg-server xinit dbus eudev font-dejavu mesa-dri-gallium" ;;
        void)      echo "xfce4 lightdm lightdm-gtk3-greeter xorg-minimal xinit dbus elogind" ;;
    esac
}

# -----------------------------------------------------------------------------
# Detecção do hardware Wi-Fi (via sysfs; não depende de lspci)
# -----------------------------------------------------------------------------
vendor_name() {
    local v="${1#0x}"; v="${v,,}"
    case "$v" in
        8086)       echo intel ;;
        10ec|0bda)  echo realtek ;;
        168c)       echo atheros ;;
        17cb)       echo qualcomm ;;
        14c3|0e8d|148f|1814) echo mediatek ;;
        14e4|0a5c)  echo broadcom ;;
        *)          echo "" ;;
    esac
}

detect_wifi_hw() {
    local d cls ven mod ifc name up
    WIFI_VENDORS=""; WIFI_MODULES=""

    for d in /sys/bus/pci/devices/*; do
        [[ -r "$d/class" ]] || continue
        cls=$(<"$d/class")
        [[ "$cls" == 0x0280* ]] || continue
        ven=$(<"$d/vendor"); name=$(vendor_name "$ven")
        [[ -n "$name" ]] && WIFI_VENDORS+="$name "
        mod=""
        if [[ -L "$d/driver/module" ]]; then
            mod=$(basename "$(readlink "$d/driver/module")")
        elif [[ -r "$d/modalias" ]] && has_cmd modprobe; then
            mod=$(modprobe -R "$(<"$d/modalias")" 2>/dev/null | head -n1)
        fi
        [[ -n "$mod" ]] && WIFI_MODULES+="$mod "
    done

    for ifc in /sys/class/net/*; do
        [[ -d "$ifc/wireless" || -d "$ifc/phy80211" ]] || continue
        mod=""; ven=""
        [[ -L "$ifc/device/driver/module" ]] && mod=$(basename "$(readlink "$ifc/device/driver/module")")
        [[ -n "$mod" ]] && WIFI_MODULES+="$mod "
        if [[ -r "$ifc/device/vendor" ]]; then ven=$(<"$ifc/device/vendor")
        else for up in "$ifc/device/../idVendor"; do [[ -r "$up" ]] && ven=$(<"$up"); done; fi
        if [[ -n "$ven" ]]; then name=$(vendor_name "$ven"); [[ -n "$name" ]] && WIFI_VENDORS+="$name "; fi
    done

    WIFI_VENDORS=$(uniq_words "$WIFI_VENDORS")
    WIFI_MODULES=$(uniq_words "$WIFI_MODULES")
}

save_manifest() {
    {
        printf 'MF_KERNEL=%q\n'    "$(uname -r)"
        printf 'MF_FAMILY=%q\n'    "$FAMILY"
        printf 'MF_VENDORS=%q\n'   "$WIFI_VENDORS"
        printf 'MF_MODULES=%q\n'   "$WIFI_MODULES"
        printf 'MF_WIFI_PKGS=%q\n' "$(get_wifi_pkgs)"
        printf 'MF_DRV_PKGS=%q\n'  "$(get_driver_pkgs)"
        printf 'MF_XFCE_PKGS=%q\n' "$(get_xfce_pkgs)"
        printf 'MF_SAVED_AT=%q\n'  "$(date '+%F %T')"
    } > "$MANIFEST"
    : > "$FW_LIST"
    local m
    for m in $WIFI_MODULES; do
        has_cmd modinfo && modinfo -F firmware "$m" 2>/dev/null >> "$FW_LIST"
    done
    sort -u "$FW_LIST" -o "$FW_LIST" 2>/dev/null || true
    log "Manifesto salvo: $MANIFEST"
}

load_manifest() {
    MF_KERNEL=""; MF_FAMILY=""; MF_VENDORS=""; MF_MODULES=""
    MF_WIFI_PKGS=""; MF_DRV_PKGS=""; MF_XFCE_PKGS=""
    # shellcheck disable=SC1090
    [[ -r "$MANIFEST" ]] && . "$MANIFEST"
    [[ -n "$MF_WIFI_PKGS" ]] || MF_WIFI_PKGS=$(get_wifi_pkgs)
    [[ -n "$MF_XFCE_PKGS" ]] || MF_XFCE_PKGS=$(get_xfce_pkgs)
    if [[ -z "$MF_DRV_PKGS" ]]; then
        WIFI_VENDORS="$MF_VENDORS"; MF_DRV_PKGS=$(get_driver_pkgs)
    fi
}

# -----------------------------------------------------------------------------
# Cache: contagem, verificação, atualização de índices
# -----------------------------------------------------------------------------
cache_count() {
    [[ -d "$1" ]] || { echo 0; return; }
    find "$1" -maxdepth 1 -type f ! -name '*.sig' 2>/dev/null | wc -l | tr -d ' '
}

cache_total() { echo $(( $(cache_count "$PKG_WIFI") + $(cache_count "$PKG_DRV") + $(cache_count "$PKG_XFCE") )); }

verify_file() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    case "$FAMILY" in
        debian)       dpkg-deb --info "$f" >/dev/null 2>&1 ;;
        fedora|rhel|suse) rpm -K --nosignature "$f" >/dev/null 2>&1 ;;
        arch)         pacman -Qp "$f" >/dev/null 2>&1 ;;
        slackware)    tar -tf "$f" >/dev/null 2>&1 ;;
        alpine)       gzip -t "$f" >/dev/null 2>&1 ;;
        *)            return 0 ;;
    esac
}

verify_cache() {
    local dir="$1" f n=0 bad=0
    [[ -d "$dir" ]] || return 0
    while IFS= read -r f; do
        ((n++))
        if ! verify_file "$f"; then warn "Arquivo corrompido: $(basename "$f")"; ((bad++)); fi
    done < <(find "$dir" -maxdepth 1 -type f ! -name '*.sig' 2>/dev/null)
    if ((bad > 0)); then warn "$bad de $n arquivos suspeitos em $(basename "$dir")."; return 1; fi
    ((n > 0)) && info "$n arquivos verificados em $(basename "$dir")."
    return 0
}

verify_all_caches() {
    local rc=0 d
    for d in "$PKG_WIFI" "$PKG_DRV" "$PKG_XFCE"; do verify_cache "$d" || rc=1; done
    return $rc
}

pm_refresh() {
    case "$FAMILY" in
        debian)      apt-get update -qq >>"$LOG_FILE" 2>&1 ;;
        fedora|rhel) "$(rpm_pm)" -q makecache >>"$LOG_FILE" 2>&1 ;;
        suse)        zypper --non-interactive refresh >>"$LOG_FILE" 2>&1 ;;
        arch)        return 0 ;;  # pacman -Syw é feito no download
        alpine)      apk update >>"$LOG_FILE" 2>&1 ;;
        void)        xbps-install -S -y >>"$LOG_FILE" 2>&1 ;;
        slackware)   has_cmd slackpkg && slackpkg -batch=on -default_answer=y update >>"$LOG_FILE" 2>&1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Download por família (sempre em diretório de staging)
#   Semântica: baixa os pacotes pedidos + dependências que faltam no sistema.
# -----------------------------------------------------------------------------
dl_debian() {
    local stage="$1"; shift
    local p cand avail="" closure q list="" installed
    for p in "$@"; do
        cand=$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ {print $2}')
        if [[ -n "$cand" && "$cand" != "(none)" ]]; then avail+="$p "; else warn "Indisponível nos repositórios: $p"; fi
    done
    [[ -n "$avail" ]] || return 1
    installed=$(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 2>/dev/null | awk '$1=="installed"{print $2}')
    # shellcheck disable=SC2086
    closure=$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
              --no-breaks --no-replaces --no-enhances $avail 2>/dev/null | grep -E '^[a-z0-9]' | sort -u)
    for q in $closure; do
        if grep -qxF -- "$q" <<<"$installed" && [[ " $avail " != *" $q "* ]]; then continue; fi
        list+="$q "
    done
    info "Baixando $(wc -w <<<"$list" | tr -d ' ') pacote(s) .deb..."
    # shellcheck disable=SC2086
    ( cd "$stage" && apt-get download $list ) >>"$LOG_FILE" 2>&1 || {
        warn "Download em lote falhou; tentando um a um..."
        for q in $list; do ( cd "$stage" && apt-get download "$q" ) >>"$LOG_FILE" 2>&1 || log "falhou: $q"; done
    }
}

dl_rpm() {
    local stage="$1"; shift
    local pm; pm=$(rpm_pm)
    local p tmp
    tmp=$(mktemp -d)
    for p in "$@"; do
        if [[ "$p" == @* ]]; then
            "$pm" install -y --downloadonly --setopt=cachedir="$tmp" --setopt=keepcache=1 "$p" \
                >>"$LOG_FILE" 2>&1 || warn "Grupo indisponível: $p"
        elif [[ "$pm" == dnf ]]; then
            dnf -y download --resolve --destdir="$stage" "$p" >>"$LOG_FILE" 2>&1 || warn "Indisponível: $p"
        else
            if has_cmd yumdownloader; then
                yumdownloader --resolve --destdir="$stage" "$p" >>"$LOG_FILE" 2>&1 || warn "Indisponível: $p"
            else
                yum install -y --downloadonly --setopt=cachedir="$tmp" --setopt=keepcache=1 "$p" \
                    >>"$LOG_FILE" 2>&1 || warn "Indisponível: $p"
            fi
        fi
    done
    find "$tmp" -name '*.rpm' -exec cp -f {} "$stage/" \; 2>/dev/null
    rm -rf "$tmp"
}

dl_suse() {
    local stage="$1"; shift
    local p tmp; tmp=$(mktemp -d)
    for p in "$@"; do
        if [[ "$p" == pattern:* ]]; then
            zypper --non-interactive --pkg-cache-dir "$tmp" install --download-only -t pattern "${p#pattern:}" \
                >>"$LOG_FILE" 2>&1 || warn "Pattern indisponível: ${p#pattern:}"
        else
            zypper --non-interactive --pkg-cache-dir "$tmp" install --download-only --force "$p" \
                >>"$LOG_FILE" 2>&1 || warn "Indisponível: $p"
        fi
    done
    find "$tmp" -name '*.rpm' -exec cp -f {} "$stage/" \; 2>/dev/null
    rm -rf "$tmp"
}

dl_arch() {
    local stage="$1"; shift
    local p flag first=1
    for p in "$@"; do
        if ((first)); then flag="-Syw"; first=0; else flag="-Sw"; fi
        pacman "$flag" --noconfirm --cachedir "$stage" "$p" >>"$LOG_FILE" 2>&1 || warn "Indisponível: $p"
    done
}

dl_slackware() {
    local stage="$1"; shift
    local p f found
    if ! has_cmd slackpkg; then
        warn "slackpkg não encontrado. Copie manualmente os pacotes .t?z para o cache."
        return 1
    fi
    warn "Slackware: slackpkg NÃO resolve dependências; o cache pode ficar incompleto."
    for p in "$@"; do
        slackpkg -batch=on -default_answer=y download "$p" >>"$LOG_FILE" 2>&1 || warn "Falha no download: $p"
        found=0
        while IFS= read -r f; do cp -f "$f" "$stage/"; found=1; done < <(
            find /var/cache/packages -type f \( -name "${p}-[0-9]*.t?z" -o -path "*/${p}/*.t?z" \) 2>/dev/null)
        ((found)) || warn "Nenhum arquivo encontrado para: $p"
    done
}

dl_alpine() {
    local stage="$1"; shift
    local p
    for p in "$@"; do
        apk fetch -R -o "$stage" "$p" >>"$LOG_FILE" 2>&1 || warn "Indisponível: $p"
    done
}

dl_void() {
    local stage="$1"; shift
    local p tmp; tmp=$(mktemp -d)
    for p in "$@"; do
        xbps-install -fSDy -c "$tmp" "$p" >>"$LOG_FILE" 2>&1 || warn "Indisponível: $p"
    done
    find "$tmp" -type f \( -name '*.xbps' -o -name '*.sig2' \) -exec cp -f {} "$stage/" \; 2>/dev/null
    rm -rf "$tmp"
}

download_set() {
    local label="$1" dir="$2"; shift 2
    local stage="${dir}.staging" n
    rm -rf "$stage"; mkdir -p "$stage"
    info "Baixando [$label]: $*"
    case "$FAMILY" in
        debian)      dl_debian "$stage" "$@" ;;
        fedora|rhel) dl_rpm "$stage" "$@" ;;
        suse)        dl_suse "$stage" "$@" ;;
        arch)        dl_arch "$stage" "$@" ;;
        slackware)   dl_slackware "$stage" "$@" ;;
        alpine)      dl_alpine "$stage" "$@" ;;
        void)        dl_void "$stage" "$@" ;;
    esac
    n=$(cache_count "$stage")
    if (( n > 0 )); then
        rm -rf "$dir"; mv "$stage" "$dir"; chmod 700 "$dir"
        info "[$label] $n arquivo(s) no cache."
    else
        rm -rf "$stage"
        warn "[$label] nada foi baixado; o cache anterior (se existir) foi mantido."
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Instalação offline a partir de um diretório do cache
#   $2 = nomes dos pacotes (necessário apenas para Void)
# -----------------------------------------------------------------------------
install_from_dir() {
    local dir="$1" names="${2:-}"
    local -a files=()
    if (( $(cache_count "$dir") == 0 )); then warn "Cache vazio: $dir"; return 1; fi
    local pm
    case "$FAMILY" in
        debian)
            DEBIAN_FRONTEND=noninteractive dpkg -i --skip-same-version --force-confdef --force-confold \
                "$dir"/*.deb >>"$LOG_FILE" 2>&1 || {
                warn "dpkg reportou erros; tentando corrigir dependências (offline)..."
                DEBIAN_FRONTEND=noninteractive apt-get -f install -y --no-download >>"$LOG_FILE" 2>&1 || {
                    warn "Correção falhou. Veja: $LOG_FILE"; return 1; }
            } ;;
        fedora|rhel)
            pm=$(rpm_pm)
            "$pm" install -y --disablerepo='*' "$dir"/*.rpm >>"$LOG_FILE" 2>&1 || {
                warn "$pm offline falhou; tentando rpm direto..."
                rpm -Uvh --replacepkgs "$dir"/*.rpm >>"$LOG_FILE" 2>&1 || { warn "rpm falhou. Veja: $LOG_FILE"; return 1; }
            } ;;
        suse)
            zypper --non-interactive --no-remote --no-refresh install --no-recommends --allow-unsigned-rpm \
                "$dir"/*.rpm >>"$LOG_FILE" 2>&1 || {
                warn "zypper offline falhou; tentando rpm direto..."
                rpm -Uvh --replacepkgs "$dir"/*.rpm >>"$LOG_FILE" 2>&1 || { warn "rpm falhou. Veja: $LOG_FILE"; return 1; }
            } ;;
        arch)
            mapfile -t files < <(find "$dir" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' | sort)
            (( ${#files[@]} > 0 )) || return 1
            pacman -U --noconfirm --needed "${files[@]}" >>"$LOG_FILE" 2>&1 || { warn "pacman -U falhou."; return 1; } ;;
        slackware)
            upgradepkg --install-new --reinstall "$dir"/*.t?z >>"$LOG_FILE" 2>&1 || { warn "upgradepkg falhou."; return 1; } ;;
        alpine)
            apk add --no-network --allow-untrusted "$dir"/*.apk >>"$LOG_FILE" 2>&1 || { warn "apk add falhou."; return 1; } ;;
        void)
            xbps-rindex -a "$dir"/*.xbps >>"$LOG_FILE" 2>&1 || true
            # shellcheck disable=SC2086
            xbps-install -y -R "$dir" $names >>"$LOG_FILE" 2>&1 || { warn "xbps-install falhou."; return 1; } ;;
    esac
    info "Instalado a partir de: $(basename "$dir")"
}

install_stack_from_cache() {
    load_manifest
    install_from_dir "$PKG_DRV"  "$MF_DRV_PKGS"  || warn "Drivers/firmware: nada instalado."
    install_from_dir "$PKG_WIFI" "$MF_WIFI_PKGS" || warn "Pacotes Wi-Fi: nada instalado."
    has_cmd depmod && depmod -a 2>>"$LOG_FILE" || true
}

install_xfce_from_cache() {
    load_manifest
    install_from_dir "$PKG_XFCE" "$MF_XFCE_PKGS"
}

# -----------------------------------------------------------------------------
# Repositórios extras para XFCE em ambientes corporativos
# -----------------------------------------------------------------------------
ensure_epel() {
    [[ "$FAMILY" == "rhel" ]] || return 0
    if [[ "$DISTRO_ID" == "amzn" ]]; then
        warn "Amazon Linux: o XFCE não está nos repositórios oficiais."; return 0
    fi
    rpm -q epel-release >/dev/null 2>&1 && return 0
    rpm -qa 2>/dev/null | grep -q '^oracle-epel-release' && return 0
    local pm; pm=$(rpm_pm)
    warn "No RHEL e derivados o XFCE vem do EPEL (repositório adicional)."
    ask "Habilitar o EPEL agora?" s || return 0
    if [[ "$DISTRO_ID" == "ol" ]]; then
        "$pm" -y install "oracle-epel-release-el${DISTRO_VER_MAJOR}" >>"$LOG_FILE" 2>&1 \
            || warn "Falha ao instalar oracle-epel-release-el${DISTRO_VER_MAJOR}."
    elif ! "$pm" -y install epel-release >>"$LOG_FILE" 2>&1; then
        warn "Não foi possível instalar o epel-release automaticamente. No RHEL:"
        echo "  subscription-manager repos --enable codeready-builder-for-rhel-${DISTRO_VER_MAJOR}-\$(arch)-rpms"
        echo "  $pm install https://dl.fedoraproject.org/pub/epel/epel-release-latest-${DISTRO_VER_MAJOR}.noarch.rpm"
    fi
    has_cmd crb && crb enable >>"$LOG_FILE" 2>&1 || true
    "$pm" -q makecache >>"$LOG_FILE" 2>&1 || true
}

ensure_packagehub() {
    case "$DISTRO_ID" in sles|sled|sles_sap) ;; *) return 0 ;; esac
    zypper lr 2>/dev/null | grep -qi packagehub && return 0
    has_cmd SUSEConnect || return 0
    warn "SLES: o XFCE vem do SUSE Package Hub (comunitário, sem suporte oficial SUSE)."
    ask "Ativar o Package Hub agora?" n || return 0
    if SUSEConnect -p "PackageHub/${DISTRO_VER}/$(uname -m)" >>"$LOG_FILE" 2>&1; then
        info "Package Hub ativado."; zypper --non-interactive refresh >>"$LOG_FILE" 2>&1 || true
    else
        warn "Falha ao ativar o Package Hub. Veja: $LOG_FILE"
    fi
}

# -----------------------------------------------------------------------------
# Backup / restauração de configurações
# -----------------------------------------------------------------------------
net_config_items() {
    cat <<'EOF'
/etc/NetworkManager
/etc/netplan
/etc/wpa_supplicant
/etc/wicked
/etc/iwd
/etc/network
/etc/systemd/network
/etc/sysconfig/network
/etc/sysconfig/network-scripts
/etc/rc.d/rc.inet1.conf
/etc/rc.d/rc.wireless.conf
/etc/conf.d/net
/etc/modprobe.d
/etc/resolv.conf
EOF
}

bk_name() { local p="${1#/}"; echo "${p//\//__}"; }

backup_to() {
    local dest="$1" item name copied=0
    mkdir -p "$dest" || { err "Falha ao criar $dest"; return 1; }
    chmod 700 "$dest"
    while IFS= read -r item; do
        [[ -e "$item" || -L "$item" ]] || continue
        name=$(bk_name "$item")
        if cp -a "$item" "$dest/$name" 2>>"$LOG_FILE"; then ((copied++)); log "Backup: $item"; else warn "Não copiou: $item"; fi
    done < <(net_config_items)

    svc_active nm > /dev/null 2>&1; echo "nm_active_rc=$?" > "$dest/_nm_active.txt"
    has_cmd rfkill && rfkill list > "$dest/_rfkill.txt" 2>&1
    has_cmd nmcli  && nmcli radio > "$dest/_nm_radio.txt" 2>&1
    has_cmd ip     && ip -br link > "$dest/_ip_link.txt" 2>&1
    has_cmd lsmod  && lsmod > "$dest/_lsmod.txt" 2>&1
    case "$FAMILY" in
        debian)           dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$dest/_packages.txt" 2>/dev/null ;;
        fedora|rhel|suse) rpm -qa > "$dest/_packages.txt" 2>/dev/null ;;
        arch)             pacman -Q > "$dest/_packages.txt" 2>/dev/null ;;
        slackware)        ls /var/log/packages/ > "$dest/_packages.txt" 2>/dev/null ;;
        alpine)           apk info -v > "$dest/_packages.txt" 2>/dev/null ;;
        void)             xbps-query -l > "$dest/_packages.txt" 2>/dev/null ;;
    esac
    {
        echo "FAMILY=$FAMILY"; echo "DISTRO=$PRETTY"; echo "KERNEL=$(uname -r)"; echo "COPIED=$copied"
    } > "$dest/_meta.env"
    BACKUP_COPIED=$copied
}

do_backup() {
    local dir="$BACKUP_ROOT/$(stamp)"
    echo "Criando backup em: $dir"
    BACKUP_COPIED=0
    backup_to "$dir" || return 1
    ln -sfn "$dir" "$BACKUP_ROOT/latest"
    info "Backup concluído: $BACKUP_COPIED item(ns) salvos."
    info "Local: $dir"
}

# Copia o CONTEÚDO de diretórios (evita aninhar) e substitui arquivos/links.
restore_item() {
    local src="$1" dst="$2"
    if [[ -d "$src" && ! -L "$src" ]]; then
        mkdir -p "$dst" && cp -a "$src/." "$dst/"
    else
        mkdir -p "$(dirname "$dst")"
        rm -f "$dst" 2>/dev/null
        cp -a "$src" "$dst"
    fi
}

backup_has_content() {
    local bdir="$1" item
    while IFS= read -r item; do
        [[ -e "$bdir/$(bk_name "$item")" || -L "$bdir/$(bk_name "$item")" ]] && return 0
    done < <(net_config_items)
    return 1
}

restore_configs() {
    local bdir="$1" item src restored=0
    while IFS= read -r item; do
        src="$bdir/$(bk_name "$item")"
        [[ -e "$src" || -L "$src" ]] || continue
        if restore_item "$src" "$item" 2>>"$LOG_FILE"; then
            ((restored++)); log "Restaurado: $item"
        else
            warn "Falha ao restaurar: $item"
        fi
        has_cmd restorecon && restorecon -R "$item" >/dev/null 2>&1
    done < <(net_config_items)
    [[ -d /etc/NetworkManager/system-connections ]] && \
        find /etc/NetworkManager/system-connections -type f -exec chmod 600 {} \; 2>/dev/null
    RESTORED_COUNT=$restored
}

# -----------------------------------------------------------------------------
# Auxiliares de Wi-Fi
# -----------------------------------------------------------------------------
wifi_iface_present() {
    local i
    for i in /sys/class/net/*; do
        [[ -d "$i/wireless" || -d "$i/phy80211" ]] && return 0
    done
    return 1
}

lsmod_has() { lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

wifi_candidate_modules() {
    local m
    for m in ${MF_MODULES:-} ${WIFI_MODULES:-} iwlwifi mt7921e mt7921u mt7925e rtw88_pci rtw89_pci \
             rtl8821ce rtl8xxxu ath9k ath10k_pci ath11k_pci ath12k brcmfmac brcmsmac wl; do
        echo "${m//-/_}"
    done | awk '!s[$0]++'
}

reload_module() {
    local m="$1" deps
    deps=$(lsmod | awk -v m="$m" '$1==m {print $4}' | tr ',' ' ')
    # shellcheck disable=SC2086
    modprobe -r $deps "$m" 2>>"$LOG_FILE" || return 1
    sleep 1
    modprobe "$m" 2>>"$LOG_FILE"
}

check_firmware() {
    [[ -s "$FW_LIST" ]] || return 0
    local f d e total=0 found=0
    while IFS= read -r f; do
        [[ -z "$f" || "$f" == *'*'* ]] && continue
        ((total++))
        for d in /lib/firmware /usr/lib/firmware; do
            for e in "" .zst .xz .gz; do
                [[ -e "$d/$f$e" ]] && { ((found++)); break 2; }
            done
        done
    done < "$FW_LIST"
    if ((total == 0)); then return 0; fi
    if ((found == 0)); then
        warn "Nenhum dos $total arquivos de firmware do driver foi encontrado em /lib/firmware."
        return 1
    fi
    info "Firmware: $found de $total arquivos listados pelo módulo estão presentes (versões extras são opcionais)."
}

check_driver_blockers() {
    local m
    for m in "$@"; do
        if grep -rEsl "^[[:space:]]*blacklist[[:space:]]+${m//_/[-_]}([[:space:]]|$)" /etc/modprobe.d /usr/lib/modprobe.d >/dev/null 2>&1; then
            warn "O módulo $m está em blacklist (/etc/modprobe.d). Remova a linha se for o driver do seu Wi-Fi."
        fi
    done
    if has_cmd mokutil && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
        warn "Secure Boot ativo: módulos de kernel não assinados não serão carregados."
    fi
    if has_cmd rfkill && rfkill list 2>/dev/null | grep -qi 'Hard blocked: yes'; then
        warn "Rádio bloqueado por HARDWARE (chave física / tecla Fn). Desbloqueie e repita."
    fi
}

# =============================================================================
# MENU 1 — Backup
# =============================================================================
# (do_backup acima)

# =============================================================================
# MENU 2 — Preparar ambiente (download + instalação)
# =============================================================================
do_prepare_environment() {
    echo -e "${CYAN}=== PREPARAR AMBIENTE: Wi-Fi + drivers/firmware + XFCE ===${NC}"
    detect_wifi_hw
    local wifi_pkgs drv_pkgs xfce_pkgs
    wifi_pkgs=$(get_wifi_pkgs); drv_pkgs=$(get_driver_pkgs); xfce_pkgs=$(get_xfce_pkgs)

    echo "Hardware Wi-Fi detectado:"
    echo "  Fabricantes: ${WIFI_VENDORS:-(não detectado — baixando firmware genérico)}"
    echo "  Módulos:     ${WIFI_MODULES:-(não detectado)}"
    echo "Pacotes Wi-Fi:      $wifi_pkgs"
    echo "Drivers/firmware:   $drv_pkgs"
    echo "Pacotes XFCE:       $xfce_pkgs"
    echo ""

    local have; have=$(cache_total)
    if (( have > 0 )); then
        info "Cache local já contém $have arquivos."
        if ! ask "Deseja baixar/atualizar pacotes da internet agora?" n; then
            info "Mantendo cache atual. Nenhuma operação de rede será feita."
            verify_all_caches || warn "Cache pode estar corrompido. Considere atualizar."
            if ask "Instalar Wi-Fi/drivers a partir do cache agora?" s; then install_stack_from_cache; fi
            if ask "Instalar XFCE a partir do cache agora?" n; then install_xfce_from_cache; fi
            return 0
        fi
    fi

    info "Verificando acesso aos repositórios..."
    if ! pm_refresh; then
        err "Não foi possível acessar os repositórios (sem rede, mirror fora do ar ou proxy)."
        err "Em rede com proxy corporativo use: sudo -E bash $0"
        (( have > 0 )) && info "O cache existente continua utilizável nas opções 3 e 4."
        return 1
    fi

    case "$FAMILY" in rhel) ensure_epel ;; suse) ensure_packagehub ;; esac

    # shellcheck disable=SC2086
    download_set wifi    "$PKG_WIFI" $wifi_pkgs || true
    # shellcheck disable=SC2086
    download_set drivers "$PKG_DRV"  $drv_pkgs  || true
    # shellcheck disable=SC2086
    download_set xfce    "$PKG_XFCE" $xfce_pkgs || true

    save_manifest
    info "Manifesto de hardware/pacotes salvo (usado pela opção 4)."
    verify_all_caches || warn "Alguns arquivos podem estar corrompidos. Tente novamente."

    echo ""
    if ask "Instalar Wi-Fi/drivers a partir do cache agora?" s; then install_stack_from_cache; fi
    if ask "Instalar XFCE a partir do cache agora?" s; then install_xfce_from_cache; fi
    info "Preparação concluída. Cache em: $PKG_ROOT"
    echo "Use a opção 8 para abrir a sessão gráfica XFCE."
}

# =============================================================================
# MENU 3 — Instalar XFCE offline
# =============================================================================
do_install_xfce_offline() {
    echo -e "${CYAN}=== INSTALAR XFCE LOCALMENTE (OFFLINE) ===${NC}"
    echo "Nenhuma tentativa de acesso à internet será feita."
    echo ""
    if (( $(cache_count "$PKG_XFCE") == 0 )); then
        err "Cache do XFCE vazio. Execute a opção 2 com internet primeiro."
        return 1
    fi
    info "Arquivos em cache (XFCE): $(cache_count "$PKG_XFCE")"
    verify_cache "$PKG_XFCE" || { err "Cache corrompido. Atualize (opção 2) antes de instalar."; return 1; }
    install_xfce_from_cache || return 1
    echo ""
    info "Instalação do XFCE concluída a partir do cache."
    echo "Use a opção 8 para abrir a sessão gráfica."
}

# =============================================================================
# MENU 4 — Restaurar Wi-Fi sem internet (drivers + módulos + configs)
# =============================================================================
do_restore_wifi() {
    echo -e "${CYAN}=== RESTAURAR WI-FI SEM INTERNET ===${NC}"
    load_manifest

    local n_wifi n_drv
    n_wifi=$(cache_count "$PKG_WIFI"); n_drv=$(cache_count "$PKG_DRV")
    if (( n_wifi + n_drv == 0 )); then
        err "Cache de Wi-Fi/drivers vazio. Execute a opção 2 uma vez com internet."
        return 1
    fi
    info "Cache: $n_wifi pacote(s) Wi-Fi, $n_drv pacote(s) de driver/firmware/módulos."
    [[ -n "$MF_MODULES" ]] && echo "  Driver(s) registrados na opção 2: $MF_MODULES (kernel $MF_KERNEL)"
    [[ -n "$MF_FAMILY" && "$MF_FAMILY" != "$FAMILY" ]] && \
        warn "O cache foi criado em outra família ($MF_FAMILY) e pode ser incompatível."
    if [[ -n "$MF_KERNEL" && "$MF_KERNEL" != "$(uname -r)" ]]; then
        warn "Kernel atual ($(uname -r)) difere do registrado ($MF_KERNEL)."
        warn "Pacotes de módulos específicos de kernel podem não corresponder; firmware continua válido."
    fi

    # 1. Integridade
    if ! verify_cache "$PKG_WIFI" || ! verify_cache "$PKG_DRV"; then
        ask "Cache com arquivos suspeitos. Continuar mesmo assim?" n || { info "Cancelado."; return 1; }
    fi

    # 2. Snapshot de segurança das configurações atuais
    local snap="$BACKUP_ROOT/pre-restore-$(stamp)"
    BACKUP_COPIED=0; backup_to "$snap" && info "Snapshot das configurações atuais: $snap"

    # 3. Pacotes: drivers/firmware/módulos primeiro, depois a pilha Wi-Fi
    install_stack_from_cache

    # 4. Carregar módulos do driver
    local m mods="$MF_MODULES"
    if [[ -z "$mods" ]]; then detect_wifi_hw; mods="$WIFI_MODULES"; fi
    check_driver_blockers $mods
    if [[ -n "$mods" ]]; then
        for m in $mods; do
            m="${m//-/_}"
            if lsmod_has "$m"; then
                info "Módulo já carregado: $m"
            elif modprobe "$m" 2>>"$LOG_FILE"; then
                info "Módulo carregado: $m"
            else
                warn "Falha ao carregar $m (kernel incompatível, firmware ausente ou Secure Boot)."
            fi
        done
    else
        warn "Nenhum módulo Wi-Fi registrado; a opção 5 tentará módulos conhecidos."
    fi
    check_firmware || true

    # 5. Restaurar configurações a partir do backup (se existir)
    svc_stop nm 2>/dev/null || true
    sleep 1
    local bdir="$BACKUP_ROOT/latest"
    if [[ -d "$bdir" ]] && backup_has_content "$bdir"; then
        restore_configs "$bdir"
        info "Configurações restauradas do backup: $RESTORED_COUNT item(ns)."
    else
        warn "Nenhum backup utilizável (opção 1). As configurações atuais foram mantidas."
    fi

    # 6. Serviços e rádio
    [[ "$INIT" == "systemd" ]] && systemctl daemon-reload 2>/dev/null
    svc_exists dbus && ! svc_active dbus && svc_start dbus
    has_cmd rfkill && rfkill unblock all 2>>"$LOG_FILE"
    svc_start nm 2>/dev/null || svc_restart nm 2>/dev/null || warn "Não foi possível iniciar o NetworkManager."
    sleep 3
    has_cmd nmcli && { nmcli connection reload 2>/dev/null; nmcli radio wifi on 2>/dev/null; }

    echo ""
    if wifi_iface_present; then
        info "Interface Wi-Fi detectada."
        has_cmd nmcli && nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | grep wifi
    else
        warn "Interface Wi-Fi ainda não detectada. Tente a opção 5 (recarrega o driver) ou reinicie."
    fi
}

# =============================================================================
# MENU 5 — Verificar serviços e reiniciar os que estiverem OFF
# =============================================================================
do_restart_services() {
    echo "Verificando serviços de rede..."
    load_manifest
    local restarted=0 logical n
    local list="dbus nm wpa"
    svc_exists nm || list="$list networkd"   # evita conflito NM x systemd-networkd

    for logical in $list; do
        svc_exists "$logical" || continue
        n=$(svc_name "$logical")
        if svc_active "$logical"; then
            echo "  $n: ativo"
        elif svc_start "$logical"; then
            info "  $n iniciado."; ((restarted++))
        else
            warn "  Falha ao iniciar: $n"
        fi
    done

    if has_cmd rfkill; then echo "Desbloqueando rfkill..."; rfkill unblock all 2>>"$LOG_FILE"; fi
    has_cmd nmcli && nmcli radio wifi on 2>>"$LOG_FILE"
    sleep 2

    if wifi_iface_present; then
        info "Interface Wi-Fi detectada."
        svc_restart nm 2>/dev/null || true
        sleep 2
        has_cmd nmcli && nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | grep wifi
        info "Serviços iniciados: $restarted"
        return 0
    fi

    warn "Interface Wi-Fi não detectada. Tentando carregar/recarregar o driver..."
    local m tried=0
    for m in $(wifi_candidate_modules); do
        if lsmod_has "$m"; then
            info "Recarregando driver: $m"
            if reload_module "$m"; then tried=1; break; else warn "Não foi possível recarregar $m (em uso?)."; fi
        fi
    done
    if (( tried == 0 )); then
        for m in ${MF_MODULES:-}; do
            m="${m//-/_}"
            lsmod_has "$m" || { modprobe "$m" 2>>"$LOG_FILE" && { info "Módulo carregado: $m"; tried=1; }; }
        done
    fi
    (( tried == 0 )) && warn "Nenhum módulo Wi-Fi conhecido pôde ser carregado. Use a opção 4."
    sleep 2
    svc_restart nm 2>/dev/null || true
    sleep 3
    if wifi_iface_present; then
        info "Interface Wi-Fi detectada."
        has_cmd nmcli && nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | grep wifi
    else
        echo "  (nenhuma interface Wi-Fi detectada)"
    fi
    info "Serviços iniciados: $restarted"
}

# =============================================================================
# MENU 6 — Rollback
# =============================================================================
do_rollback() {
    echo -e "${RED}=== ROLLBACK: RETORNAR AO AMBIENTE ORIGINAL ===${NC}"
    local bdir="$BACKUP_ROOT/latest"
    [[ -d "$bdir" ]] || { err "Nenhum backup encontrado. Use a opção 1."; return 1; }
    if ! backup_has_content "$bdir"; then
        err "Backup vazio ou incompleto. Rollback abortado para não destruir a configuração atual."
        return 1
    fi
    echo "Backup: $(readlink -f "$bdir")"
    ask "Confirmar rollback?" n || { info "Cancelado."; return 0; }

    local snap="$BACKUP_ROOT/pre-rollback-$(stamp)"
    BACKUP_COPIED=0; backup_to "$snap" && info "Snapshot do estado atual: $snap"

    svc_stop nm 2>/dev/null || true
    svc_stop wpa 2>/dev/null || true
    sleep 1
    restore_configs "$bdir"
    [[ "$INIT" == "systemd" ]] && systemctl daemon-reload 2>/dev/null
    svc_start nm 2>/dev/null || true
    sleep 3
    info "Rollback concluído. $RESTORED_COUNT item(ns) restaurados."
    echo "Observação: o rollback restaura configurações; pacotes instalados não são removidos."
}

# =============================================================================
# MENU 7 — Diagnóstico do cache
# =============================================================================
do_diagnose_cache() {
    echo -e "${CYAN}=== DIAGNÓSTICO DO CACHE ===${NC}"
    load_manifest
    echo "Sistema: $PRETTY | família: $FAMILY | init: $INIT | kernel: $(uname -r)"
    if (( $(cache_total) == 0 )); then
        warn "Cache vazio. Execute a opção 2 com internet."
    else
        info "Wi-Fi:    $(cache_count "$PKG_WIFI") arquivo(s)"
        info "Drivers:  $(cache_count "$PKG_DRV") arquivo(s)"
        info "XFCE:     $(cache_count "$PKG_XFCE") arquivo(s)"
        has_cmd du && echo "  Tamanho total: $(du -sh "$PKG_ROOT" 2>/dev/null | cut -f1)"
        verify_all_caches || true
    fi
    echo ""
    if [[ -r "$MANIFEST" ]]; then
        echo "Manifesto (opção 2):"
        echo "  Fabricantes Wi-Fi: ${MF_VENDORS:-?}"
        echo "  Módulos:           ${MF_MODULES:-?}"
        echo "  Kernel registrado: ${MF_KERNEL:-?}"
        echo "  Drivers/firmware:  ${MF_DRV_PKGS:-?}"
        [[ -n "$MF_KERNEL" && "$MF_KERNEL" != "$(uname -r)" ]] && warn "Kernel atual diferente do registrado."
    else
        warn "Sem manifesto: execute a opção 2 para registrar o hardware Wi-Fi."
    fi
    echo ""
    echo "Backups disponíveis (mais recentes):"
    ls -1t "$BACKUP_ROOT" 2>/dev/null | head -5 | sed 's/^/  /'
    [[ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]] && echo "  (nenhum)"
    echo ""
    echo "Ferramentas:"
    local t
    for t in nmcli rfkill iw modprobe startxfce4 startx; do
        if has_cmd "$t"; then echo "  $t: ok"; else echo "  $t: ausente"; fi
    done
}

# =============================================================================
# MENU 8 — Abrir sessão gráfica XFCE
# =============================================================================
xfce_installed() { has_cmd startxfce4 || has_cmd xfce4-session; }

active_dm() {
    local dm
    for dm in lightdm gdm gdm3 sddm lxdm slim xdm; do
        if [[ "$INIT" == "systemd" ]]; then
            systemctl is-active --quiet "$dm" 2>/dev/null && { echo "$dm"; return 0; }
        else
            pgrep -x "$dm" >/dev/null 2>&1 && { echo "$dm"; return 0; }
        fi
    done
    return 1
}

set_lightdm_xfce_default() {
    [[ -f /usr/share/xsessions/xfce.desktop ]] || return 0
    [[ -d /etc/lightdm ]] || return 0
    mkdir -p /etc/lightdm/lightdm.conf.d
    umask 022
    cat > /etc/lightdm/lightdm.conf.d/50-wifi-recovery-xfce.conf <<'EOF'
[Seat:*]
user-session=xfce

[SeatDefaults]
user-session=xfce
EOF
    umask 077
    log "LightDM: sessão padrão = xfce (/etc/lightdm/lightdm.conf.d/50-wifi-recovery-xfce.conf)"
    info "XFCE definido como sessão padrão do LightDM."
}

start_xfce_with_startx() {
    if ! has_cmd startx && ! has_cmd xinit; then
        err "startx/xinit não encontrado (pacote xinit / xorg-xinit / xorg-x11-xinit)."; return 1
    fi
    local user="${SUDO_USER:-}" tty_dev owner n bin
    if [[ -z "$user" || "$user" == "root" ]]; then
        read -r -p "Usuário comum que usará a sessão gráfica: " user
    fi
    if [[ -z "$user" || "$user" == "root" ]] || ! id "$user" >/dev/null 2>&1; then
        err "Usuário inválido. Não é recomendado executar o XFCE como root."; return 1
    fi
    tty_dev=$(tty 2>/dev/null || true)
    if [[ "$tty_dev" != /dev/tty[0-9]* ]]; then
        err "Este terminal ($tty_dev) não é um console virtual."
        echo "Troque para um TTY (Ctrl+Alt+F3), faça login e execute:  startxfce4   (ou: startx)"
        return 1
    fi
    bin=$(command -v startxfce4)
    owner=$(stat -c '%U:%G' "$tty_dev" 2>/dev/null || echo "root:tty")
    n="${tty_dev#/dev/tty}"
    chown "$user" "$tty_dev" 2>/dev/null
    info "Iniciando XFCE como '$user' em $tty_dev (ao encerrar a sessão você volta ao menu)..."
    if has_cmd startx; then
        su -l "$user" -c "exec startx '$bin' -- vt$n"
    else
        su -l "$user" -c "exec xinit '$bin' -- vt$n"
    fi
    local rc=$?
    chown "$owner" "$tty_dev" 2>/dev/null
    (( rc != 0 )) && warn "A sessão terminou com erro (código $rc). Se falhou ao abrir o Xorg, faça login no TTY como '$user' e execute: startxfce4"
    return 0
}

do_open_xfce_session() {
    echo -e "${CYAN}=== ABRIR SESSÃO GRÁFICA XFCE ===${NC}"

    # 1. XFCE instalado?
    if ! xfce_installed; then
        warn "XFCE não está instalado."
        if (( $(cache_count "$PKG_XFCE") > 0 )) && ask "Instalar a partir do cache local agora?" s; then
            verify_cache "$PKG_XFCE" || warn "Cache com arquivos suspeitos."
            install_xfce_from_cache
        fi
        xfce_installed || { err "XFCE indisponível. Use as opções 2 e 3."; return 1; }
    fi

    # 2. Já existe sessão XFCE?
    if pgrep -x xfce4-session >/dev/null 2>&1; then
        info "Já existe uma sessão XFCE em execução."; return 0
    fi

    # 3. Este terminal está dentro de outra sessão gráfica?
    if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        warn "Este terminal está dentro de uma sessão gráfica. Iniciar outra pode causar conflito."
        echo "Recomendado: Ctrl+Alt+F3 (TTY), login, e executar este menu novamente."
        ask "Continuar mesmo assim?" n || return 0
    fi

    # 4. Pré-requisito: barramento de mensagens (D-Bus)
    svc_exists dbus && ! svc_active dbus && svc_start dbus

    # 5. Já existe gerenciador de login ativo?
    local cur_dm
    if cur_dm=$(active_dm); then
        info "O gerenciador de login '$cur_dm' já está ativo."
        echo "Na tela de login escolha a sessão 'Xfce Session' (seletor/engrenagem) e entre."
        [[ "$cur_dm" == "lightdm" ]] && ask "Definir XFCE como sessão padrão do LightDM?" s && set_lightdm_xfce_default
        if has_cmd chvt && ask "Alternar para a tela gráfica agora?" s; then
            chvt 7 2>/dev/null || chvt 1 2>/dev/null || true
        fi
        return 0
    fi

    # 6. Escolher método
    local opt has_dm=0
    if has_cmd lightdm && svc_exists dm; then has_dm=1; fi
    echo ""
    echo "Como deseja abrir a sessão gráfica?"
    (( has_dm )) && echo "  1) Iniciar o gerenciador de login (LightDM) — recomendado"
    echo "  2) Iniciar o XFCE direto neste console (startx), como usuário comum"
    [[ "$INIT" == "slackrc" && -x /etc/rc.d/rc.4 ]] && echo "  3) Mudar para o runlevel 4 (login gráfico do Slackware)"
    echo "  0) Cancelar"
    read -r -p "Escolha: " opt

    case "$opt" in
        1)
            (( has_dm )) || { warn "Opção indisponível."; return 1; }
            if ask "Definir XFCE como sessão padrão do LightDM?" s; then set_lightdm_xfce_default; fi
            info "Iniciando o LightDM..."
            if svc_start dm; then
                sleep 2
                has_cmd chvt && { chvt 7 2>/dev/null || true; }
                info "Tela gráfica iniciada. Se não aparecer, tente Ctrl+Alt+F7 ou F1."
                ask "Habilitar o login gráfico a cada boot?" n && svc_enable dm
            else
                err "Falha ao iniciar o LightDM. Veja: $LOG_FILE"
            fi ;;
        2) start_xfce_with_startx ;;
        3)
            if [[ "$INIT" == "slackrc" && -x /etc/rc.d/rc.4 ]]; then
                warn "Isto encerra o modo texto atual e abre o login gráfico."
                ask "Confirmar telinit 4?" n && telinit 4
            else
                warn "Opção inválida."
            fi ;;
        0) info "Cancelado." ;;
        *) warn "Opção inválida." ;;
    esac
}

# =============================================================================
# MENU PRINCIPAL
# =============================================================================
show_menu() {
    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        WIFI RECOVERY MENU v$SCRIPT_VERSION${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e "  Sistema: $PRETTY"
    echo -e "  Família: $FAMILY   Init: $INIT"
    echo -e "  Cache:   $CACHE_DIR"
    local total; total=$(cache_total)
    if (( total > 0 )); then
        echo -e "  Offline: ${GREEN}SIM${NC} (wifi: $(cache_count "$PKG_WIFI"), drivers: $(cache_count "$PKG_DRV"), xfce: $(cache_count "$PKG_XFCE"))"
    else
        echo -e "  Offline: ${YELLOW}NÃO${NC} (cache vazio — opção 2 precisa de internet)"
    fi
    echo -e "${CYAN}==================================================${NC}"
    echo ""
    echo "  1- Fazer backup completo do ambiente de redes e Wi-Fi"
    echo "  2- Verificar ambiente, baixar pacotes (Wi-Fi + drivers + XFCE) e instalar"
    echo "  3- Instalar XFCE localmente (offline, a partir do cache)"
    echo "  4- Restaurar Wi-Fi sem internet (drivers, firmware, módulos e configs)"
    echo "  5- Verificar serviços de rede e reiniciar os que estiverem OFF"
    echo "  6- Rollback: retornar o ambiente original com o backup criado"
    echo "  7- Diagnosticar cache local (verificar integridade dos pacotes)"
    echo "  8- Abrir sessão gráfica XFCE"
    echo ""
    echo "  0- SAIR"
    echo ""
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${YELLOW}Dica:${NC} As opções 3 a 8 operam 100% offline se o cache existir."
    echo ""
}

main_loop() {
    local opt
    while true; do
        show_menu
        read -r -p "Escolha uma opção: " opt
        echo ""
        case "$opt" in
            1) do_backup; echo ""; read -r -p "ENTER..." _ ;;
            2) do_prepare_environment; echo ""; read -r -p "ENTER..." _ ;;
            3) do_install_xfce_offline; echo ""; read -r -p "ENTER..." _ ;;
            4) do_restore_wifi; echo ""; read -r -p "ENTER..." _ ;;
            5) do_restart_services; echo ""; read -r -p "ENTER..." _ ;;
            6) do_rollback; echo ""; read -r -p "ENTER..." _ ;;
            7) do_diagnose_cache; echo ""; read -r -p "ENTER..." _ ;;
            8) do_open_xfce_session; echo ""; read -r -p "ENTER..." _ ;;
            0) info "Saindo."; exit 0 ;;
            *) warn "Opção inválida."; sleep 1 ;;
        esac
    done
}

main() {
    case "${1:-}" in
        -h|--help)    usage; exit 0 ;;
        -V|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
    esac
    check_root
    init_dirs
    detect_distro
    detect_init
    log "Menu iniciado. Distro: $PRETTY ($FAMILY), init: $INIT. Cache: $PKG_ROOT"
    main_loop
}

# Permite "source" do arquivo para testes sem iniciar o menu
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
