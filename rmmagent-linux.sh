#!/bin/bash

# [validação de argumentos omitida para brevidade, mantida como antes]

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
go_version="1.21.6"

go_url_amd64="https://go.dev/dl/go$go_version.linux-amd64.tar.gz"
go_url_x86="https://go.dev/dl/go$go_version.linux-386.tar.gz"
go_url_arm64="https://go.dev/dl/go$go_version.linux-arm64.tar.gz"
go_url_armv6="https://go.dev/dl/go$go_version.linux-armv6l.tar.gz"

function go_install() {
    if ! command -v go &> /dev/null; then
        echo "Installing Go $go_version..."
        case $system in
            amd64) wget -O /tmp/golang.tar.gz "$go_url_amd64" ;;
            x86) wget -O /tmp/golang.tar.gz "$go_url_x86" ;;
            arm64) wget -O /tmp/golang.tar.gz "$go_url_arm64" ;;
            armv6) wget -O /tmp/golang.tar.gz "$go_url_armv6" ;;
        esac
        rm -rf /usr/local/go/
        tar -xzf /tmp/golang.tar.gz -C /usr/local/
        rm /tmp/golang.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        echo "Go $go_version installed."
    else
        go_current_version=$(go version | awk '{print $3}' | sed 's/go//')
        if [[ "$go_current_version" != "$go_version" ]]; then
            echo "Version mismatch. Current: $go_current_version, Desired: $go_version. Reinstalling..."
            case $system in
                amd64) wget -O /tmp/golang.tar.gz "$go_url_amd64" ;;
                x86) wget -O /tmp/golang.tar.gz "$go_url_x86" ;;
                arm64) wget -O /tmp/golang.tar.gz "$go_url_arm64" ;;
                armv6) wget -O /tmp/golang.tar.gz "$go_url_armv6" ;;
            esac
            rm -rf /usr/local/go/
            tar -xzf /tmp/golang.tar.gz -C /usr/local/
            rm /tmp/golang.tar.gz
            export PATH=$PATH:/usr/local/go/bin
            echo "Go $go_version installed."
        else
            echo "Go is up to date (version $go_current_version)."
        fi
    fi
}

function agent_compile() {
    echo "Compiling Tactical RMM Agent..."
    wget -O /tmp/rmmagent.tar.gz "https://github.com/amidaware/rmmagent/archive/refs/heads/master.tar.gz"
    tar -xf /tmp/rmmagent.tar.gz -C /tmp/
    rm /tmp/rmmagent.tar.gz
    cd /tmp/rmmagent-master || exit 1

    # Limpa o cache e remove o go.sum para evitar validação de checksum
    echo "Cleaning Go module cache and removing go.sum..."
    go clean -modcache
    rm -f go.sum

    # Desativa validação de checksum remoto
    export GOSUMDB=off

    # Compila diretamente, usando -mod=readonly para evitar alterações no go.mod
    echo "Building agent for $system..."
    case $system in
        amd64)
            env GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -mod=readonly -tags "linux" -ldflags "-s -w" -o /tmp/temp_rmmagent || {
                echo "Compilation failed. Check the error above."
                exit 1
            }
            ;;
        x86)
            env GOOS=linux GOARCH=386 CGO_ENABLED=0 go build -mod=readonly -tags "linux" -ldflags "-s -w" -o /tmp/temp_rmmagent || {
                echo "Compilation failed. Check the error above."
                exit 1
            }
            ;;
        arm64)
            env GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -mod=readonly -tags "linux" -ldflags "-s -w" -o /tmp/temp_rmmagent || {
                echo "Compilation failed. Check the error above."
                exit 1
            }
            ;;
        armv6)
            env GOOS=linux GOARCH=arm GOARM=6 CGO_ENABLED=0 go build -mod=readonly -tags "linux" -ldflags "-s -w" -o /tmp/temp_rmmagent || {
                echo "Compilation failed. Check the error above."
                exit 1
            }
            ;;
    esac

    if [[ ! -f /tmp/temp_rmmagent ]]; then
        echo "Error: Failed to compile the agent. Binary not found."
        exit 1
    fi
    echo "Agent compiled successfully."
    cd /tmp
    rm -rf /tmp/rmmagent-master
}

function update_agent() {
    systemctl stop tacticalagent
    cp /tmp/temp_rmmagent /usr/local/bin/rmmagent
    rm /tmp/temp_rmmagent
    systemctl start tacticalagent
}

function install_agent() {
    cp /tmp/temp_rmmagent /usr/local/bin/rmmagent
    /usr/local/bin/rmmagent -m install -api "$rmm_url" -client-id "$rmm_client_id" -site-id "$rmm_site_id" -agent-type "$rmm_agent_type" -auth "$rmm_auth"
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
    systemctl enable --now tacticalagent
}

function install_mesh() {
    wget -O /tmp/meshagent "$mesh_url"
    chmod +x /tmp/meshagent
    mkdir -p /opt/tacticalmesh
    /tmp/meshagent -install --installPath="/opt/tacticalmesh"
    rm /tmp/meshagent /tmp/meshagent.msh 2>/dev/null
}

function check_profile() {
    profile_file="/root/.profile"
    if ! grep -q "export PATH=\$PATH:/usr/local/go/bin" "$profile_file"; then
        echo "Adding Go to PATH in $profile_file..."
        echo "export PATH=\$PATH:/usr/local/go/bin" >> "$profile_file"
    fi
    export PATH=$PATH:/usr/local/go/bin
}

function uninstall_agent() {
    systemctl stop tacticalagent
    systemctl disable tacticalagent
    rm -f /etc/systemd/system/tacticalagent.service
    systemctl daemon-reload
    rm -f /usr/local/bin/rmmagent
    rm -rf /etc/tacticalagent
    sed -i "/export PATH=\$PATH:\/usr\/local\/go\/bin/d" /root/.profile
}

function uninstall_mesh() {
    wget "https://$mesh_fqdn/meshagents?script=1" -O /tmp/meshinstall.sh || wget "https://$mesh_fqdn/meshagents?script=1" --no-proxy -O /tmp/meshinstall.sh
    chmod +x /tmp/meshinstall.sh
    /tmp/meshinstall.sh uninstall "https://$mesh_fqdn" "$mesh_id" || true
    rm -f /tmp/meshinstall.sh /opt/tacticalmesh/meshagent /opt/tacticalmesh/meshagent.msh 2>/dev/null
}

case $1 in
    install)
        check_profile
        go_install
        install_mesh
        agent_compile
        install_agent
        echo "Tactical Agent Install is done"
        exit 0;;
    update)
        check_profile
        go_install
        agent_compile
        update_agent
        echo "Tactical Agent Update is done"
        exit 0;;
    uninstall)
        check_profile
        uninstall_agent
        uninstall_mesh
        echo "Tactical Agent Uninstall is done"
        echo "You may need to manually remove the agents' orphaned connections on TacticalRMM and MeshCentral"
        exit 0;;
esac
