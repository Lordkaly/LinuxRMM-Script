#!/bin/bash

# Função para exibir erro e sair
error_exit() {
    echo "$1"
    echo "Type 'help' for more information"
    exit 1
}

# Verificação inicial de argumentos
[ -z "$1" ] && error_exit "First argument is empty!"

if [ "$1" = "help" ]; then
    echo "More information available at github.com/amidaware/rmmagent-script"
    echo ""
    echo "INSTALL arguments:"
    echo "  1: 'install'"
    echo "  2: System type ('amd64' 'x86' 'arm64' 'armv6')"
    echo "  3: Mesh agent URL"
    echo "  4: API URL"
    echo "  5: Client ID"
    echo "  6: Site ID"
    echo "  7: Auth Key"
    echo "  8: Agent Type ('server' or 'workstation')"
    echo ""
    echo "UPDATE arguments:"
    echo "  1: 'update'"
    echo "  2: System type ('amd64' 'x86' 'arm64' 'armv6')"
    echo ""
    echo "UNINSTALL arguments:"
    echo "  1: 'uninstall'"
    echo "  2: Mesh agent FQDN (e.g., mesh.example.com)"
    echo "  3: Mesh agent ID (in single quotes)"
    exit 0
fi

# Validação do primeiro argumento
[[ "$1" != "install" && "$1" != "update" && "$1" != "uninstall" ]] && error_exit "First argument must be 'install', 'update', or 'uninstall'!"

# Validações específicas por comando
if [ "$1" = "install" ] || [ "$1" = "update" ]; then
    [ -z "$2" ] && error_exit "Argument 2 (System type) is empty!"
    [[ "$2" != "amd64" && "$2" != "x86" && "$2" != "arm64" && "$2" != "armv6" ]] && error_exit "System type must be 'amd64', 'x86', 'arm64', or 'armv6'!"
fi

if [ "$1" = "install" ]; then
    [ -z "$3" ] && error_exit "Argument 3 (Mesh agent URL) is empty!"
    [ -z "$4" ] && error_exit "Argument 4 (API URL) is empty!"
    [ -z "$5" ] && error_exit "Argument 5 (Client ID) is empty!"
    [ -z "$6" ] && error_exit "Argument 6 (Site ID) is empty!"
    [ -z "$7" ] && error_exit "Argument 7 (Auth Key) is empty!"
    [ -z "$8" ] && error_exit "Argument 8 (Agent Type) is empty!"
    [[ "$8" != "server" && "$8" != "workstation" ]] && error_exit "Agent Type must be 'server' or 'workstation'!"
fi

if [ "$1" = "uninstall" ]; then
    [ -z "$2" ] && error_exit "Argument 2 (Mesh agent FQDN) is empty!"
    [ -z "$3" ] && error_exit "Argument 3 (Mesh agent ID) is empty!"
fi

# Variáveis
system=$2
mesh_url=$3
rmm_url=$4
rmm_client_id=$5
rmm_site_id=$6
rmm_auth=$7
rmm_agent_type=$8
mesh_fqdn=$2
mesh_id=$3
go_version="1.22.0"

go_url_amd64="https://go.dev/dl/go$go_version.linux-amd64.tar.gz"
go_url_x86="https://go.dev/dl/go$go_version.linux-386.tar.gz"
go_url_arm64="https://go.dev/dl/go$go_version.linux-arm64.tar.gz"
go_url_armv6="https://go.dev/dl/go$go_version.linux-armv6l.tar.gz"

# Função para instalar Go
go_install() {
    if ! /usr/local/go/bin/go version &>/dev/null || ! /usr/local/go/bin/go version | grep -q "go$go_version"; then
        echo "Installing or updating Go to $go_version..."
        case $system in
            amd64) wget -O /tmp/golang.tar.gz "$go_url_amd64" ;;
            x86) wget -O /tmp/golang.tar.gz "$go_url_x86" ;;
            arm64) wget -O /tmp/golang.tar.gz "$go_url_arm64" ;;
            armv6) wget -O /tmp/golang.tar.gz "$go_url_armv6" ;;
        esac
        rm -rf /usr/local/go/
        tar -xzf /tmp/golang.tar.gz -C /usr/local/
        rm /tmp/golang.tar.gz
        export PATH=/usr/local/go/bin:$PATH
        echo "Go $go_version installed."
    else
        echo "Go is up to date (version $go_version)."
    fi
    # Verifica se o Go está funcionando
    if ! /usr/local/go/bin/go version &>/dev/null; then
        error_exit "Go installation failed or not found in /usr/local/go/bin!"
    fi
    echo "Go version after install: $(/usr/local/go/bin/go version)"
}

# Função para compilar o agente
agent_compile() {
    echo "Compiling Tactical RMM Agent (v2.9.0)..."
    wget -O /tmp/rmmagent.tar.gz "https://github.com/amidaware/rmmagent/archive/refs/tags/v2.9.0.tar.gz" || error_exit "Failed to download rmmagent v2.9.0!"
    tar -xf /tmp/rmmagent.tar.gz -C /tmp/ || error_exit "Failed to extract rmmagent!"
    rm /tmp/rmmagent.tar.gz
    cd /tmp/rmmagent-2.9.0 || error_exit "Directory /tmp/rmmagent-2.9.0 not found!"
    
    # Força o PATH para usar o Go instalado
    export PATH=/usr/local/go/bin:$PATH
    
    # Verifica o ambiente Go
    echo "Go version: $(/usr/local/go/bin/go version)"
    echo "Current PATH: $PATH"
    if ! /usr/local/go/bin/go version &>/dev/null; then
        error_exit "Go is not installed or not found in /usr/local/go/bin!"
    fi
    
    # Tenta limpar o cache do Go, mas continua se falhar
    echo "Cleaning Go module cache..."
    /usr/local/go/bin/go clean -modcache || echo "Warning: Failed to clean Go module cache, proceeding anyway..."

    # Atualiza o go.mod para Go 1.22
    echo "Updating go.mod to use Go $go_version..."
    sed -i 's/go 1\.[0-9]\+/go 1.22/' go.mod || echo "Warning: Failed to update go.mod, proceeding anyway..."
    
    # Remove o go.sum existente para evitar conflitos
    echo "Removing existing go.sum to force refresh..."
    rm -f go.sum
    
    # Inicializa o módulo e baixa dependências com saída detalhada
    echo "Tidying Go modules (verbose output)..."
    /usr/local/go/bin/go mod tidy -v 2>&1 || error_exit "Failed to tidy Go modules after resetting go.sum! See output above for details."
    
    echo "Downloading Go dependencies..."
    /usr/local/go/bin/go mod download -x || error_exit "Failed to download Go dependencies!"
    
    # Compilação
    echo "Building agent..."
    case $system in
        amd64) env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 /usr/local/go/bin/go build -ldflags "-s -w" -o /tmp/temp_rmmagent ;;
        x86) env CGO_ENABLED=0 GOOS=linux GOARCH=386 /usr/local/go/bin/go build -ldflags "-s -w" -o /tmp/temp_rmmagent ;;
        arm64) env CGO_ENABLED=0 GOOS=linux GOARCH=arm64 /usr/local/go/bin/go build -ldflags "-s -w" -o /tmp/temp_rmmagent ;;
        armv6) env CGO_ENABLED=0 GOOS=linux GOARCH=arm /usr/local/go/bin/go build -ldflags "-s -w" -o /tmp/temp_rmmagent ;;
    esac
    [ ! -f /tmp/temp_rmmagent ] && error_exit "Compilation failed: /tmp/temp_rmmagent not created!"
    
    cd /tmp
    rm -rf /tmp/rmmagent-2.9.0
}

# Função para atualizar o agente
update_agent() {
    systemctl stop tacticalagent || echo "Warning: Failed to stop tacticalagent."
    cp /tmp/temp_rmmagent /usr/local/bin/rmmagent || error_exit "Failed to copy agent binary!"
    rm /tmp/temp_rmmagent
    systemctl start tacticalagent || error_exit "Failed to start tacticalagent!"
}

# Função para instalar o agente
install_agent() {
    cp /tmp/temp_rmmagent /usr/local/bin/rmmagent || error_exit "Failed to copy agent binary!"
    /usr/local/bin/rmmagent -m install -api "$rmm_url" -client-id "$rmm_client_id" -site-id "$rmm_site_id" -agent-type "$rmm_agent_type" -auth "$rmm_auth" || error_exit "Agent installation failed!"
    rm /tmp/temp_rmmagent

    cat << "EOF" > /etc/systemd/system/tacticalagent.service
[Unit]
Description=Tactical RMM Linux Agent
[Service]
Type=simple
ExecStart=/usr/local/bin/rmmagent -m svc
User=root
Group=root
Restart=always
RestartSec=5s
LimitNOFILE=1000000
KillMode=process
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now tacticalagent || error_exit "Failed to enable tacticalagent!"
    systemctl start tacticalagent || error_exit "Failed to start tacticalagent!"
}

# Função para instalar o Mesh
install_mesh() {
    wget -O /tmp/meshagent "$mesh_url" || error_exit "Failed to download mesh agent!"
    chmod +x /tmp/meshagent
    mkdir -p /opt/tacticalmesh
    /tmp/meshagent -install --installPath="/opt/tacticalmesh" || error_exit "Mesh agent installation failed!"
    rm /tmp/meshagent /tmp/meshagent.msh 2>/dev/null
}

# Função para ajustar o PATH
check_profile() {
    profile_file="/root/.profile"
    if grep -q "export PATH=/usr/local/go/bin" "$profile_file"; then
        echo "Removing incorrect PATH variable(s)"
        sed -i "/export PATH=\/usr\/local\/go\/bin/d" "$profile_file"
    fi
    if ! grep -q "export PATH=\$PATH:/usr/local/go/bin" "$profile_file"; then
        echo "Fixing PATH variable"
        echo "export PATH=\$PATH:/usr/local/go/bin" >> "$profile_file"
    fi
    export PATH=/usr/local/go/bin:$PATH
}

# Função para desinstalar o agente
uninstall_agent() {
    systemctl stop tacticalagent 2>/dev/null
    systemctl disable tacticalagent 2>/dev/null
    rm -f /etc/systemd/system/tacticalagent.service
    systemctl daemon-reload
    rm -f /usr/local/bin/rmmagent
    rm -rf /etc/tacticalagent
    sed -i "/export PATH=\$PATH:\/usr\/local\/go\/bin/d" /root/.profile
}

# Função para desinstalar o Mesh
uninstall_mesh() {
    wget "https://$mesh_fqdn/meshagents?script=1" -O /tmp/meshinstall.sh || error_exit "Failed to download mesh uninstall script!"
    chmod 755 /tmp/meshinstall.sh
    /tmp/meshinstall.sh uninstall "https://$mesh_fqdn" "$mesh_id" || error_exit "Mesh uninstall failed!"
    rm -f /tmp/meshinstall.sh meshagent meshagent.msh 2>/dev/null
}

# Execução principal
case $1 in
    install)
        check_profile
        go_install
        install_mesh
        agent_compile
        install_agent
        echo "Tactical Agent Install is done"
        ;;
    update)
        check_profile
        go_install
        agent_compile
        update_agent
        echo "Tactical Agent Update is done"
        ;;
    uninstall)
        check_profile
        uninstall_agent
        uninstall_mesh
        echo "Tactical Agent Uninstall is done"
        echo "You may need to manually remove orphaned connections on TacticalRMM and MeshCentral"
        ;;
esac

exit 0
