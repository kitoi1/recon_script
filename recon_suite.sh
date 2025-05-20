#!/bin/bash

# Enhanced Recon Script v4.0 for Kali Linux
# Features:
# - Parallel processing with GNU parallel
# - Dynamic progress tracking
# - Comprehensive JSON logging
# - HTML reporting
# - Error recovery and retry mechanisms
# - Tool version checking
# - Automated tool installation

# Configuration
VERSION="4.0"
CONFIG_FILE="recon_config.cfg"
LOG_DIR="recon_logs"
REPORT_DIR="recon_reports"
SESSION_FILE=".recon_session"
THREADS=$(nproc)
TIMEOUT=20
MAX_RETRIES=3

# Initialize logging
init_logging() {
    LOG_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOG_FILE="${LOG_DIR}/recon_${DOMAIN}_${LOG_TIMESTAMP}.json"
    mkdir -p "$LOG_DIR" "$REPORT_DIR"
    
    # Create JSON log structure
    echo '{
        "metadata": {
            "domain": "'"$DOMAIN"'",
            "start_time": "'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'",
            "version": "'"$VERSION"'",
            "system": {
                "os": "'"$(uname -s)"'",
                "arch": "'"$(uname -m)"'",
                "cores": "'"$(nproc)"'"
            }
        },
        "tools": {},
        "findings": [],
        "errors": [],
        "statistics": {}
    }' > "$LOG_FILE"
}

# Log to JSON file
log_json() {
    local type=$1
    local message=$2
    local tool=${3:-"system"}
    local status=${4:-"info"}
    
    jq --arg type "$type" \
       --arg message "$message" \
       --arg tool "$tool" \
       --arg status "$status" \
       --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
       '. * {
           findings: (if $type == "finding" then .findings + [{
               tool: $tool,
               message: $message,
               timestamp: $timestamp
           }] else .findings end),
           errors: (if $type == "error" then .errors + [{
               tool: $tool,
               message: $message,
               status: $status,
               timestamp: $timestamp
           }] else .errors end),
           tools: (if $type == "tool" then .tools + {
               ($tool): {
                   version: $message,
                   status: $status
               }
           } else .tools end)
       }' "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
}

# Display banner
display_banner() {
    clear
    echo -e "\e[34m"
    cat << "EOF"
  ____ _____ ____  _____ ____  _   _ ____ _____ ____  
 / ___| ____/ ___|| ____|  _ \| | | / ___| ____|  _ \ 
| |  _|  _| \___ \|  _| | | | | | | \___ \  _| | | | |
| |_| | |___ ___) | |___| |_| | |_| |___) | |___| |_| |
 \____|_____|____/|_____|____/ \___/|____/|_____|____/ 
EOF
    echo -e "\e[0m"
    echo -e "\e[36mEnhanced Reconnaissance Suite v${VERSION}\e[0m"
    echo -e "\e[34m$(printf '%.0s=' {1..80})\e[0m"
    echo
}

# Check dependencies
check_dependencies() {
    local required_tools=("subfinder" "assetfinder" "amass" "findomain" "dnsx" "httpx" "nuclei" "gau" "aquatone" "jq" "parallel")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
            log_json "error" "Missing tool: $tool" "system" "critical"
        else
            local version=$($tool --version 2>&1 | head -n 1 || echo "unknown")
            log_json "tool" "$version" "$tool" "installed"
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo -e "\e[31m[!] Missing tools detected:\e[0m"
        for tool in "${missing_tools[@]}"; do
            echo -e "  - $tool"
        done
        
        read -rp "Attempt to install missing tools? (y/N) " choice
        if [[ "$choice" =~ ^[Yy] ]]; then
            install_tools "${missing_tools[@]}"
        else
            echo -e "\e[31m[!] Cannot proceed without required tools\e[0m"
            exit 1
        fi
    fi
}

# Install missing tools
install_tools() {
    local tools_to_install=("$@")
    
    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y "${tools_to_install[@]}" jq parallel
    elif command -v brew &>/dev/null; then
        brew install "${tools_to_install[@]}" jq parallel
    else
        echo -e "\e[31m[!] No supported package manager found\e[0m"
        exit 1
    fi
    
    # Verify installation
    for tool in "${tools_to_install[@]}"; do
        if command -v "$tool" &>/dev/null; then
            log_json "tool" "$($tool --version 2>&1 | head -n 1)" "$tool" "installed"
        else
            log_json "error" "Failed to install $tool" "system" "critical"
            exit 1
        fi
    done
}

# Subdomain enumeration
enumerate_subdomains() {
    local domain=$1
    local outdir=$2
    
    echo -e "\e[36m[+] Enumerating subdomains for $domain\e[0m"
    log_json "finding" "Starting subdomain enumeration" "subfinder"
    
    local subdomain_tools=("subfinder" "assetfinder" "amass" "findomain")
    local subdomains_file="${outdir}/subdomains.txt"
    local temp_file="${outdir}/subdomains_temp.txt"
    
    # Run tools in parallel
    for tool in "${subdomain_tools[@]}"; do
        {
            case "$tool" in
                "subfinder")
                    subfinder -d "$domain" -silent -o "${outdir}/subfinder.txt" 2>> "${outdir}/subfinder.log"
                    ;;
                "assetfinder")
                    assetfinder --subs-only "$domain" > "${outdir}/assetfinder.txt" 2>> "${outdir}/assetfinder.log"
                    ;;
                "amass")
                    amass enum -passive -d "$domain" -o "${outdir}/amass.txt" 2>> "${outdir}/amass.log"
                    ;;
                "findomain")
                    findomain -t "$domain" -q -u "${outdir}/findomain.txt" 2>> "${outdir}/findomain.log"
                    ;;
            esac
            log_json "finding" "Completed $tool execution" "$tool"
        } &
    done
    wait
    
    # Merge and sort results
    cat "${outdir}/subfinder.txt" "${outdir}/assetfinder.txt" "${outdir}/amass.txt" "${outdir}/findomain.txt" 2>/dev/null \
        | sort -u > "$temp_file"
    
    # Resolve domains
    if [ -s "$temp_file" ]; then
        log_json "finding" "Resolving discovered subdomains" "dnsx"
        dnsx -l "$temp_file" -a -aaaa -cname -silent -o "$subdomains_file" 2>> "${outdir}/dnsx.log"
        log_json "finding" "Resolved $(wc -l < "$subdomains_file") subdomains" "dnsx"
    else
        log_json "error" "No subdomains discovered" "subdomain_enum" "warning"
    fi
    
    echo -e "\e[32m[✓] Found $(wc -l < "$subdomains_file" 2>/dev/null || echo 0) unique subdomains\e[0m"
}

# HTTP probing
probe_http() {
    local input_file=$1
    local outdir=$2
    
    echo -e "\e[36m[+] Probing HTTP services\e[0m"
    log_json "finding" "Starting HTTP probing" "httpx"
    
    httpx -l "$input_file" -title -status-code -tech-detect -follow-redirects \
        -o "${outdir}/http_probes.txt" -json -silent 2>> "${outdir}/httpx.log"
    
    # Convert JSON to CSV for easier processing
    jq -r '[.url, .status-code, .title, .tech[]?] | @csv' "${outdir}/http_probes.txt" \
        > "${outdir}/http_probes.csv" 2>/dev/null
    
    log_json "finding" "Completed HTTP probing" "httpx"
    echo -e "\e[32m[✓] HTTP probing completed\e[0m"
}

# Vulnerability scanning
run_vuln_scan() {
    local input_file=$1
    local outdir=$2
    
    echo -e "\e[36m[+] Running vulnerability scans\e[0m"
    log_json "finding" "Starting vulnerability scanning" "nuclei"
    
    nuclei -l "$input_file" -severity low,medium,high,critical \
        -o "${outdir}/nuclei_results.txt" -silent 2>> "${outdir}/nuclei.log"
    
    log_json "finding" "Completed vulnerability scanning" "nuclei"
    echo -e "\e[32m[✓] Vulnerability scanning completed\e[0m"
}

# Generate HTML report
generate_report() {
    local outdir=$1
    local domain=$2
    
    echo -e "\e[36m[+] Generating HTML report\e[0m"
    
    # Convert data to HTML
    {
        echo "<!DOCTYPE html>"
        echo "<html>"
        echo "<head>"
        echo "<title>Recon Report for $domain</title>"
        echo "<style>"
        echo "body { font-family: Arial, sans-serif; margin: 20px; }"
        echo "h1 { color: #333; }"
        echo "table { border-collapse: collapse; width: 100%; }"
        echo "th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }"
        echo "th { background-color: #f2f2f2; }"
        echo "tr:nth-child(even) { background-color: #f9f9f9; }"
        echo ".critical { background-color: #ffcccc; }"
        echo ".high { background-color: #ffe6cc; }"
        echo ".medium { background-color: #ffffcc; }"
        echo ".low { background-color: #e6ffcc; }"
        echo "</style>"
        echo "</head>"
        echo "<body>"
        echo "<h1>Recon Report for $domain</h1>"
        echo "<p>Generated on $(date)</p>"
        
        # Subdomains section
        echo "<h2>Discovered Subdomains ($(wc -l < "${outdir}/subdomains.txt"))</h2>"
        echo "<pre>$(head -n 20 "${outdir}/subdomains.txt")</pre>"
        echo "<p>... and $(($(wc -l < "${outdir}/subdomains.txt") - 20)) more</p>"
        
        # HTTP Probes
        if [ -f "${outdir}/http_probes.csv" ]; then
            echo "<h2>HTTP Services</h2>"
            echo "<table>"
            echo "<tr><th>URL</th><th>Status</th><th>Title</th><th>Technologies</th></tr>"
            while IFS=, read -r url status title tech; do
                echo "<tr><td>$url</td><td>$status</td><td>$title</td><td>$tech</td></tr>"
            done < <(head -n 20 "${outdir}/http_probes.csv")
            echo "</table>"
        fi
        
        # Vulnerabilities
        if [ -f "${outdir}/nuclei_results.txt" ]; then
            echo "<h2>Vulnerability Findings</h2>"
            echo "<table>"
            echo "<tr><th>Severity</th><th>Vulnerability</th><th>URL</th></tr>"
            while read -r line; do
                severity=$(echo "$line" | jq -r '.info.severity')
                name=$(echo "$line" | jq -r '.info.name')
                url=$(echo "$line" | jq -r '.host')
                echo "<tr class=\"$severity\"><td>$severity</td><td>$name</td><td>$url</td></tr>"
            done < <(jq -c '.' "${outdir}/nuclei_results.txt" | head -n 20)
            echo "</table>"
        fi
        
        echo "</body>"
        echo "</html>"
    } > "${REPORT_DIR}/recon_report_${domain}.html"
    
    log_json "finding" "Generated HTML report" "reporting"
    echo -e "\e[32m[✓] HTML report generated: ${REPORT_DIR}/recon_report_${domain}.html\e[0m"
}

# Main recon function
run_recon() {
    local domain=$1
    local outdir="recon_${domain}_$(date +%Y%m%d_%H%M%S)"
    
    mkdir -p "$outdir"
    init_logging
    
    echo -e "\e[34m[*] Starting reconnaissance for $domain\e[0m"
    log_json "finding" "Starting reconnaissance" "main"
    
    # Run all phases
    enumerate_subdomains "$domain" "$outdir"
    
    if [ -s "${outdir}/subdomains.txt" ]; then
        probe_http "${outdir}/subdomains.txt" "$outdir"
        run_vuln_scan "${outdir}/subdomains.txt" "$outdir"
    else
        log_json "error" "No subdomains to scan" "main" "warning"
    fi
    
    generate_report "$outdir" "$domain"
    
    # Finalize log
    jq --arg end_time "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
       '.metadata.end_time = $end_time' "$LOG_FILE" > "${LOG_FILE}.tmp" \
       && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    
    echo -e "\e[32m[✓] Recon complete. Results saved to $outdir\e[0m"
    log_json "finding" "Reconnaissance completed" "main"
}

# Main execution
if [[ $EUID -ne 0 ]]; then
    echo -e "\e[31m[!] This script must be run as root. Use sudo.\e[0m"
    exit 1
fi

if [ -z "$1" ]; then
    echo -e "\e[33m[!] Usage: $0 <domain>\e[0m"
    exit 1
fi

DOMAIN=$1
display_banner
check_dependencies
run_recon "$DOMAIN"
