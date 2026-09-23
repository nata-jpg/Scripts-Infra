#!/bin/bash
#
# Instalação e configuração automática do Zabbix Agent 2
# Compatível com: Debian, Ubuntu, RHEL/CentOS/Rocky/AlmaLinux/Oracle Linux, SUSE (SLES)
# Autor: Gerado para Natã - Solid Tecnologia
#
# NOVIDADE: o script agora detecta automaticamente qual versão do Zabbix
# (dentre as candidatas abaixo) possui pacote de repositório publicado
# para a distro/versão detectada, em vez de usar uma versão fixa.
# Prioriza a versão do Zabbix Server informada em ZABBIX_SERVER_VERSION e,
# se não houver pacote pra ela na distro, cai para as próximas da lista.
#
# Uso: ./install_zabbix_agent2.sh   (o próprio script se auto-eleva via sudo)
#

set -e

# ---------- Versão do Zabbix Server e ordem de fallback ----------
# Ajuste ZABBIX_SERVER_VERSION conforme o ambiente. O script tenta primeiro
# esta versão; se a distro não tiver pacote pra ela, testa as seguintes,
# na ordem em que aparecem no array.
ZABBIX_SERVER_VERSION="6.0"
ZABBIX_CANDIDATES=("6.0" "6.4" "7.0" "7.4")

# ---------- Cores para output ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[AVISO]${NC} $1"; }
error() { echo -e "${RED}[ERRO]${NC} $1"; }

# ---------- Garante execução como root (auto-eleva via sudo se necessário) ----------
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        warn "Script não está rodando como root. Reexecutando com sudo..."
        exec sudo bash "$0" "$@"
    else
        error "Este script precisa ser executado como root e o comando 'sudo' não foi encontrado."
        exit 1
    fi
fi

# ---------- Detecta hostname atual ----------
CURRENT_HOSTNAME=$(hostname)
info "Hostname detectado no sistema: ${CURRENT_HOSTNAME}"

# ---------- Detecta distribuição, família e versão ----------
if [ ! -f /etc/os-release ]; then
    error "Não foi possível detectar a distribuição (/etc/os-release não encontrado)."
    exit 1
fi
. /etc/os-release

OS_ID="${ID}"
OS_VERSION_ID="${VERSION_ID}"
OS_MAJOR="${VERSION_ID%%.*}"   # parte antes do primeiro ponto (ex: 9.3 -> 9)

FAMILY=""
case "$OS_ID" in
    debian|ubuntu)
        FAMILY="debian"
        ;;
    rhel|centos|rocky|almalinux|ol|fedora)
        FAMILY="rhel"
        ;;
    sles|sled|opensuse-leap|opensuse)
        FAMILY="suse"
        ;;
    *)
        # Fallback: tenta pelo ID_LIKE
        case "${ID_LIKE:-}" in
            *debian*)  FAMILY="debian" ;;
            *rhel*|*fedora*)  FAMILY="rhel" ;;
            *suse*)    FAMILY="suse" ;;
            *)
                error "Distribuição '${OS_ID}' não é suportada por este script."
                error "Suportadas: Debian, Ubuntu, RHEL/CentOS/Rocky/Alma/Oracle Linux, SUSE (SLES)."
                exit 1
                ;;
        esac
        ;;
esac

info "Distribuição detectada: ${PRETTY_NAME:-$OS_ID $OS_VERSION_ID} (família: ${FAMILY})"

# =========================================================
# HELPERS DE REDE (curl com fallback pra wget)
# =========================================================
http_get() {
    # Imprime o conteúdo da URL no stdout. Não derruba o script em falha
    # (mesmo com 'set -e' ativo), pois é usado dentro de testes.
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 10 "$url" 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=10 "$url" 2>/dev/null || true
    fi
}

download_file() {
    # download_file <url> <destino>
    local url="$1" dest="$2"
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$dest" "$url"
    else
        error "Nem 'wget' nem 'curl' disponíveis para baixar arquivos."
        return 1
    fi
}

# =========================================================
# DETECÇÃO AUTOMÁTICA DA VERSÃO DO ZABBIX COMPATÍVEL
# =========================================================
# Para uma versão candidata do Zabbix, consulta o índice real do
# repositório e retorna a URL completa do pacote zabbix-release
# encontrado para esta distro/versão. Retorna vazio se não achar.
find_repo_package() {
    local zbx_version="$1"
    local dir_url pattern listing matches best

    case "$FAMILY" in
        debian)
            dir_url="https://repo.zabbix.com/zabbix/${zbx_version}/${OS_ID}/pool/main/z/zabbix-release/"
            pattern="zabbix-release[^\"[:space:]]*${OS_ID}${OS_VERSION_ID}_all\.deb"
            ;;
        rhel)
            dir_url="https://repo.zabbix.com/zabbix/${zbx_version}/rhel/${OS_MAJOR}/x86_64/"
            pattern="zabbix-release[^\"[:space:]]*\.el${OS_MAJOR}\.noarch\.rpm"
            ;;
        suse)
            dir_url="https://repo.zabbix.com/zabbix/${zbx_version}/sles/${OS_MAJOR}/x86_64/"
            pattern="zabbix-release[^\"[:space:]]*\.sles${OS_MAJOR}\.noarch\.rpm"
            ;;
        *)
            return 1
            ;;
    esac

    listing="$(http_get "$dir_url")"
    [ -z "$listing" ] && return 1

    matches="$(echo "$listing" | grep -oE "$pattern" | sort -u)"
    [ -z "$matches" ] && return 1

    # Prioriza o nome que contenha "latest"; senão pega o de maior versão
    best="$(echo "$matches" | grep "latest" | head -n1)"
    [ -z "$best" ] && best="$(echo "$matches" | sort -V | tail -n1)"
    [ -z "$best" ] && return 1

    echo "${dir_url}${best}"
}

info "Detectando a versão mais recente do Zabbix com pacote disponível para esta distro..."
REPO_PKG_URL=""
ZABBIX_MAJOR=""

for v in "${ZABBIX_CANDIDATES[@]}"; do
    info "   Testando Zabbix ${v}..."
    if url="$(find_repo_package "$v")" && [ -n "$url" ]; then
        REPO_PKG_URL="$url"
        ZABBIX_MAJOR="$v"
        info "   -> Encontrado: Zabbix ${v} (${url##*/})"
        break
    else
        warn "   -> Sem pacote de repositório para Zabbix ${v} em ${OS_ID} ${OS_VERSION_ID}."
    fi
done

if [ -z "$REPO_PKG_URL" ]; then
    error "Nenhuma das versões testadas (${ZABBIX_CANDIDATES[*]}) tem pacote de repositório"
    error "para ${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}. Confira manualmente em:"
    error "https://www.zabbix.com/download"
    exit 1
fi

if [ "$ZABBIX_MAJOR" != "$ZABBIX_SERVER_VERSION" ]; then
    warn "O Zabbix Server deste ambiente é ${ZABBIX_SERVER_VERSION}, mas será instalado o agent ${ZABBIX_MAJOR}"
    warn "(não há pacote para ${ZABBIX_SERVER_VERSION} nesta distro). Normalmente funciona sem problema"
    warn "para monitoramento padrão, mas pode gerar avisos de 'version mismatch' no log do agent."
fi

# O Zabbix Agent 2 não é suportado no SLES 12 (apenas SLES 15 SP1+).
# Nesse caso, o script cai automaticamente para o Agent clássico (zabbix-agent).
USE_AGENT2=true
if [ "$FAMILY" = "suse" ] && [ "$OS_MAJOR" = "12" ]; then
    warn "Zabbix Agent 2 não é suportado no SLES 12 (apenas SLES 15 SP1+)."
    warn "Este servidor usará automaticamente o Zabbix Agent clássico (zabbix-agent) em vez do agent2."
    USE_AGENT2=false
fi

# ---------- Pergunta o IP do Zabbix Proxy/Server ----------
read -rp "Digite o IP (ou hostname) do Zabbix Proxy/Server: " ZABBIX_SERVER_IP
if [ -z "$ZABBIX_SERVER_IP" ]; then
    error "IP/hostname do Zabbix Proxy/Server não pode ser vazio."
    exit 1
fi

# ---------- Pergunta se deseja usar hostname diferente ----------
read -rp "Deseja usar o hostname '${CURRENT_HOSTNAME}' no Zabbix? [S/n]: " USE_HOSTNAME
USE_HOSTNAME=${USE_HOSTNAME:-S}
if [[ "$USE_HOSTNAME" =~ ^[Nn]$ ]]; then
    read -rp "Digite o nome de host a ser utilizado no Zabbix: " ZABBIX_HOSTNAME
else
    ZABBIX_HOSTNAME="$CURRENT_HOSTNAME"
fi

info "Configuração definida:"
echo "   -> Distribuição:            ${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"
echo "   -> Versão do Zabbix:        ${ZABBIX_MAJOR} $([ "$ZABBIX_MAJOR" != "$ZABBIX_SERVER_VERSION" ] && echo "(Server é ${ZABBIX_SERVER_VERSION})")"
echo "   -> Agente a instalar:       $([ "$USE_AGENT2" = true ] && echo 'Zabbix Agent 2 (zabbix-agent2)' || echo 'Zabbix Agent clássico (zabbix-agent)')"
echo "   -> Zabbix Proxy/Server IP:  ${ZABBIX_SERVER_IP}"
echo "   -> Hostname no Zabbix:      ${ZABBIX_HOSTNAME}"
echo ""
read -rp "Confirma a instalação com esses dados? [S/n]: " CONFIRM
CONFIRM=${CONFIRM:-S}
if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
    warn "Instalação cancelada pelo usuário."
    exit 0
fi

# =========================================================
# INSTALAÇÃO DO REPOSITÓRIO E DO PACOTE, POR FAMÍLIA DE SO
# =========================================================
PKG_INSTALLED_CHECK=""   # comando usado na verificação final

case "$FAMILY" in

    debian)
        info "Atualizando lista de pacotes..."
        apt-get update -y

        info "Baixando repositório Zabbix ${ZABBIX_MAJOR} (${OS_ID} ${OS_VERSION_ID})..."
        TMP_DEB="/tmp/zabbix-release.deb"
        download_file "$REPO_PKG_URL" "$TMP_DEB" || {
            error "Falha ao baixar o repositório em: ${REPO_PKG_URL}"
            exit 1
        }
        dpkg -i "$TMP_DEB"
        apt-get update -y

        info "Instalando o Zabbix Agent 2..."
        apt-get install -y zabbix-agent2

        ZABBIX_PKG_NAME="zabbix-agent2"
        ZABBIX_CONF="/etc/zabbix/zabbix_agent2.conf"
        SERVICE_NAME="zabbix-agent2"
        PKG_INSTALLED_CHECK="dpkg -s zabbix-agent2"
        ;;

    rhel)
        PKG_MGR="dnf"
        command -v dnf >/dev/null 2>&1 || PKG_MGR="yum"

        info "Instalando repositório Zabbix ${ZABBIX_MAJOR} (RHEL/${OS_MAJOR} via ${PKG_MGR})..."
        # Se o pacote zabbix-release já estiver instalado (mesma versão),
        # 'rpm -Uvh' retorna erro mesmo sem problema real — não tratamos
        # isso como falha fatal, só seguimos em frente.
        if ! rpm -Uvh --nosignature "$REPO_PKG_URL" 2>/tmp/rpm_repo_err; then
            if grep -qi "already installed" /tmp/rpm_repo_err; then
                warn "Pacote de repositório zabbix-release já estava instalado. Prosseguindo."
            else
                error "Falha ao instalar o repositório em: ${REPO_PKG_URL}"
                cat /tmp/rpm_repo_err
                exit 1
            fi
        fi

        "$PKG_MGR" clean all
        info "Instalando o Zabbix Agent 2..."
        "$PKG_MGR" install -y zabbix-agent2

        ZABBIX_PKG_NAME="zabbix-agent2"
        ZABBIX_CONF="/etc/zabbix/zabbix_agent2.conf"
        SERVICE_NAME="zabbix-agent2"
        PKG_INSTALLED_CHECK="rpm -q zabbix-agent2"
        ;;

    suse)
        info "Instalando repositório Zabbix ${ZABBIX_MAJOR} (SLES ${OS_MAJOR})..."
        if ! rpm -Uvh --nosignature "$REPO_PKG_URL" 2>/tmp/rpm_repo_err; then
            if grep -qi "already installed" /tmp/rpm_repo_err; then
                warn "Pacote de repositório zabbix-release já estava instalado. Prosseguindo."
            else
                error "Falha ao instalar o repositório em: ${REPO_PKG_URL}"
                cat /tmp/rpm_repo_err
                exit 1
            fi
        fi

        zypper --gpg-auto-import-keys refresh 'Zabbix Official Repository'

        if [ "$USE_AGENT2" = true ]; then
            info "Instalando o Zabbix Agent 2..."
            zypper --non-interactive install zabbix-agent2
            ZABBIX_PKG_NAME="zabbix-agent2"
            ZABBIX_CONF="/etc/zabbix/zabbix_agent2.conf"
            SERVICE_NAME="zabbix-agent2"
        else
            info "Instalando o Zabbix Agent clássico (SLES 12 não suporta agent2)..."
            zypper --non-interactive install zabbix-agent
            ZABBIX_PKG_NAME="zabbix-agent"
            ZABBIX_CONF="/etc/zabbix/zabbix_agentd.conf"
            SERVICE_NAME="zabbix-agent"
        fi
        PKG_INSTALLED_CHECK="rpm -q ${ZABBIX_PKG_NAME}"
        ;;
esac

# =========================================================
# CONFIGURAÇÃO DO AGENTE (comum a todas as distros)
# =========================================================
if [ ! -f "$ZABBIX_CONF" ]; then
    error "Arquivo de configuração ${ZABBIX_CONF} não encontrado. Instalação pode ter falhado."
    exit 1
fi

info "Fazendo backup do arquivo de configuração original..."
cp "$ZABBIX_CONF" "${ZABBIX_CONF}.bak.$(date +%Y%m%d%H%M%S)"

info "Aplicando configurações no ${ZABBIX_CONF}..."
sed -i "s/^Server=.*/Server=${ZABBIX_SERVER_IP}/" "$ZABBIX_CONF"
sed -i "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER_IP}/" "$ZABBIX_CONF"
sed -i "s/^Hostname=.*/Hostname=${ZABBIX_HOSTNAME}/" "$ZABBIX_CONF"

grep -q "^Server=" "$ZABBIX_CONF" || echo "Server=${ZABBIX_SERVER_IP}" >> "$ZABBIX_CONF"
grep -q "^ServerActive=" "$ZABBIX_CONF" || echo "ServerActive=${ZABBIX_SERVER_IP}" >> "$ZABBIX_CONF"
grep -q "^Hostname=" "$ZABBIX_CONF" || echo "Hostname=${ZABBIX_HOSTNAME}" >> "$ZABBIX_CONF"

# =========================================================
# FIREWALL — detecta ufw ou firewalld, aplica o que existir
# =========================================================
FIREWALL_APLICADO="nenhum"

if command -v ufw >/dev/null 2>&1; then
    info "UFW encontrado. Liberando porta 10050/tcp..."
    ufw allow 10050/tcp
    ufw reload
    FIREWALL_APLICADO="ufw"
elif command -v firewall-cmd >/dev/null 2>&1; then
    info "firewalld encontrado. Liberando porta 10050/tcp..."
    firewall-cmd --permanent --add-port=10050/tcp
    firewall-cmd --reload
    FIREWALL_APLICADO="firewalld"
else
    warn "Nenhum firewall gerenciável (ufw/firewalld) encontrado. Se houver iptables/nftables manual, libere a porta 10050/tcp manualmente."
fi

# =========================================================
# CONFLITO COM AGENT CLÁSSICO NA PORTA 10050
# =========================================================
# Se o zabbix-agent (v1) estiver instalado e ativo, ele vai brigar pela
# porta 10050 com o agent2 recém-instalado. Detecta e resolve automaticamente.
if [ "$USE_AGENT2" = true ] && systemctl list-unit-files 2>/dev/null | grep -q "^zabbix-agent\.service"; then
    if systemctl is-active --quiet zabbix-agent; then
        warn "Zabbix Agent clássico (v1) está ativo e vai conflitar na porta 10050 com o agent2."
        warn "Parando e desabilitando zabbix-agent (v1)..."
        systemctl stop zabbix-agent
        systemctl disable zabbix-agent
    fi
fi

# =========================================================
# HABILITA E INICIA O SERVIÇO
# =========================================================
info "Habilitando o serviço ${SERVICE_NAME} para iniciar no boot..."
systemctl enable "$SERVICE_NAME"

info "Reiniciando o serviço ${SERVICE_NAME}..."
systemctl restart "$SERVICE_NAME"

# =========================================================
# VERIFICAÇÃO FINAL
# =========================================================
sleep 2
echo ""
echo "================= VERIFICAÇÃO ================="

if $PKG_INSTALLED_CHECK >/dev/null 2>&1; then
    info "Pacote ${ZABBIX_PKG_NAME}: INSTALADO com sucesso."
else
    error "Pacote ${ZABBIX_PKG_NAME} NÃO foi instalado corretamente."
    exit 1
fi

if systemctl is-active --quiet "$SERVICE_NAME"; then
    info "Serviço ${SERVICE_NAME}: RODANDO."
else
    error "Serviço ${SERVICE_NAME} NÃO está rodando. Verifique com: systemctl status ${SERVICE_NAME}"
    error "Dica: journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
    exit 1
fi

echo "================================================="
echo ""
info "Resumo da instalação:"
echo "   -> Distribuição:                   ${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"
echo "   -> Versão do Zabbix instalada:     ${ZABBIX_MAJOR}"
echo "   -> Agente instalado:               ${ZABBIX_PKG_NAME}"
echo "   -> Hostname configurado no Zabbix: ${ZABBIX_HOSTNAME}"
echo "   -> Zabbix Proxy/Server:            ${ZABBIX_SERVER_IP}"
echo "   -> Arquivo de configuração:        ${ZABBIX_CONF}"
echo "   -> Firewall configurado:           ${FIREWALL_APLICADO}"
echo ""
info "Instalação e configuração do ${ZABBIX_PKG_NAME} concluídas com sucesso!"
info "Para verificar logs em caso de dúvida: tail -f /var/log/zabbix/${SERVICE_NAME}.log"
