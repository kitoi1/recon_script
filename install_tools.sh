#!/bin/bash

# Recon Suite Tool Installer
# Fixed version without syntax errors

echo "[*] Installing required tools..."

# Install from package manager
sudo apt-get update
sudo apt-get install -y jq parallel golang python3-pip

# Install Go tools
GO_TOOLS=(
    "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    "github.com/projectdiscovery/assetfinder@latest"
    "github.com/OWASP/Amass/v3/...@master"
    "github.com/Edu4rdSHL/findomain@latest"
    "github.com/projectdiscovery/dnsx/cmd/dnsx@latest"
    "github.com/projectdiscovery/httpx/cmd/httpx@latest"
    "github.com/projectdiscovery/nuclei/v2/cmd/nuclei@latest"
    "github.com/lc/gau/v2/cmd/gau@latest"
    "github.com/tomnomnom/waybackurls@latest"
    "github.com/haccer/subjack@latest"
    "github.com/projectdiscovery/naabu/v2/cmd/naabu@latest"
    "github.com/ffuf/ffuf@latest"
    "github.com/michenriksen/aquatone@latest"
)

for tool in "${GO_TOOLS[@]}"; do
    echo "[*] Installing $tool"
    go install "$tool"
done

# Add Go binaries to PATH
if ! grep -q 'go/bin' ~/.bashrc; then
    echo 'export PATH=$PATH:$(go env GOPATH)/bin' >> ~/.bashrc
    echo "[*] Added Go binaries to PATH in ~/.bashrc"
fi

# Source bashrc to update current session
source ~/.bashrc

echo "[+] Installation complete!"
echo "[!] Please restart your terminal or run 'source ~/.bashrc' to update your PATH"
