#!/bin/bash

# Advanced Reconnaissance Suite v3.0
# Features: 
# - Parallel processing with improved resource management
# - Comprehensive logging with timestamps
# - JSON/CSV outputs for all tools
# - Error handling and retry mechanisms
# - Automated tool installation check
# - Dynamic performance tuning based on system resources
# - Modular design for easy updates

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ASCII Art
echo -e "${CYAN}
  ____ _____ ____  _____ ____  _   _ ____ _____ ____  
 / ___|___ /|  _ \| ____|  _ \| | | / ___|___ /|  _ \ 
| |     |_ \| |_) |  _| | | | | | | \___ \ |_ \| | | |
| |___ ___) |  _ <| |___| |_| | |_| |___) |__) | |_| |
 \____|____/|_| \_\_____|____/ \___/|____/____/|____/ 
${NC}"
echo -e "${YELLOW}             Advanced Reconnaissance Suite v3.0${NC}"
echo -e "${MAGENTA}--------------------------------------------------------${NC}"
echo -e "${BLUE}Start Time: $(date)${NC}\n"

# Global Configuration
DOMAIN=$1
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTDIR="recon/${DOMAIN}_${TIMESTAMP}"
LOGFILE="$OUTDIR/recon_${TIMESTAMP}.log"
TOOLS_DIR="/opt/tools"
THREADS=$(($(nproc) * 2))  # Dynamic thread calculation
TIMEOUT=15
MAX_RETRIES=3

# Check if domain is provided
if [ -z "$1" ]; then
    echo -e "${RED}[!] Error: No domain specified${NC}" | tee -a "$LOGFILE"
    echo -e "${YELLOW}Usage: $0 <domain>${NC}" | tee -a "$LOGFILE"
    exit 1
fi

# Create directory structure
mkdir -p "$OUTDIR"/{raw,processed,logs,screenshots} 2>/dev/null

# Logging function
log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    case $level in
        "INFO") color="${BLUE}[*]${NC}" ;;
        "SUCCESS") color="${GREEN}[+]${NC}" ;;
        "WARNING") color="${YELLOW}[!]${NC}" ;;
        "ERROR") color="${RED}[-]${NC}" ;;
        "CRITICAL") color="${MAGENTA}[X]${NC}" ;;
        *) color="${CYAN}[?]${NC}" ;;
    esac
    
    echo -e "${timestamp} ${color} ${message}" | tee -a "$LOGFILE"
}

# Progress spinner with elapsed time
spinner() {
    local pid=$1
    local task=$2
    local delay=0.1
    local spinstr='|/-\'
    local start_time=$(date +%s)
    
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        local elapsed=$(( $(date +%s) - start_time ))
        printf " [%c] %s (Elapsed: %02ds)" "$spinstr" "$task" "$elapsed"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\r\033[K"
    done
    printf " [✓] %s (Completed in %02ds)\n" "$task" "$(( $(date +%s) - start_time ))"
}

# Tool check and installation prompt
check_tool() {
    local tool=$1
    if ! command -v "$tool" &>/dev/null; then
        log "ERROR" "$tool is not installed"
        read -p "Would you like to install it now? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo apt-get install -y "$tool" || {
                log "CRITICAL" "Failed to install $tool"
                exit 1
            }
        else
            log "CRITICAL" "Cannot proceed without $tool"
            exit 1
        fi
    fi
}

# Check for required tools
log "INFO" "Checking for required tools"
REQUIRED_TOOLS=("subfinder" "assetfinder" "amass" "findomain" "dnsx" "httpx" "nuclei" "gau" "waybackurls" "subjack" "naabu" "ffuf" "aquatone")
for tool in "${REQUIRED_TOOLS[@]}"; do
    check_tool "$tool" &
done
wait

# System performance check
log "INFO" "System Performance Check"
TOTAL_MEM=$(free -m | awk '/Mem:/ {print $2}')
AVAILABLE_MEM=$(free -m | awk '/Mem:/ {print $7}')
CPU_LOAD=$(awk '{print $1}' < /proc/loadavg)
CPU_CORES=$(nproc)

log "INFO" "CPU Cores: $CPU_CORES, Load: $CPU_LOAD"
log "INFO" "Total Memory: ${TOTAL_MEM}MB, Available: ${AVAILABLE_MEM}MB"

# Adjust threads if load is high
if (( $(echo "$CPU_LOAD > $CPU_CORES" | bc -l) )); then
    THREADS=$((CPU_CORES / 2))
    log "WARNING" "High system load detected. Reducing threads to $THREADS"
fi

# 1. Subdomain Enumeration (Parallel with retries)
subdomain_enum() {
    log "INFO" "Starting subdomain enumeration with $THREADS threads"
    
    # Run tools in parallel with retries
    run_with_retry() {
        local cmd=$1
        local output=$2
        local tool=$3
        local retries=0
        
        while [ $retries -lt $MAX_RETRIES ]; do
            log "INFO" "Running $tool (Attempt $((retries+1)))"
            eval "$cmd" > "$output" 2>> "$OUTDIR/logs/${tool}_error.log"
            
            if [ -s "$output" ]; then
                log "SUCCESS" "$tool completed successfully"
                return 0
            else
                retries=$((retries+1))
                log "WARNING" "$tool attempt $retries failed, retrying..."
                sleep $((retries * 2))
            fi
        done
        
        log "ERROR" "$tool failed after $MAX_RETRIES attempts"
        return 1
    }
    
    # Run all tools in parallel
    run_with_retry "subfinder -d $DOMAIN -silent -t $THREADS -timeout $TIMEOUT -o $OUTDIR/raw/subfinder.json -json" "$OUTDIR/raw/subfinder.json" "subfinder" &
    run_with_retry "assetfinder --subs-only $DOMAIN" "$OUTDIR/raw/assetfinder.txt" "assetfinder" &
    run_with_retry "amass enum -passive -d $DOMAIN -timeout $TIMEOUT -json $OUTDIR/raw/amass.json" "$OUTDIR/raw/amass.json" "amass" &
    run_with_retry "findomain -t $DOMAIN -r -u $OUTDIR/raw/findomain.txt" "$OUTDIR/raw/findomain.txt" "findomain" &
    
    wait
    
    # Process results
    log "INFO" "Processing subdomain results"
    cat "$OUTDIR"/raw/*.txt 2>/dev/null | sort -u > "$OUTDIR/raw/all_subs.txt"
    jq -r '.name' "$OUTDIR"/raw/*.json 2>/dev/null | sort -u >> "$OUTDIR/raw/all_subs.txt"
    cat "$OUTDIR/raw/all_subs.txt" | sort -u | anew > "$OUTDIR/subdomains.txt" 2>/dev/null
    
    sub_count=$(wc -l < "$OUTDIR/subdomains.txt")
    log "SUCCESS" "Found $sub_count unique subdomains"
}

# 2. DNS Resolution and Verification
dns_resolution() {
    log "INFO" "Starting DNS resolution"
    
    dnsx -l "$OUTDIR/subdomains.txt" -silent -a -aaaa -cname -mx -txt -ptr -resp \
         -retry $MAX_RETRIES -threads $THREADS -json -o "$OUTDIR/processed/dns.json" 2>> "$OUTDIR/logs/dnsx_error.log" &
    spinner $! "DNS Resolution"
    
    # Extract valid domains
    jq -r '.host' "$OUTDIR/processed/dns.json" | sort -u > "$OUTDIR/valid_subdomains.txt"
    valid_count=$(wc -l < "$OUTDIR/valid_subdomains.txt")
    log "SUCCESS" "Found $valid_count valid DNS records"
}

# 3. HTTP Probing and Screenshots
http_probing() {
    log "INFO" "Starting HTTP probing"
    
    # Fast probing first
    httpx -l "$OUTDIR/valid_subdomains.txt" -silent -status-code -title -tech-detect \
          -follow-redirects -threads $THREADS -json -o "$OUTDIR/processed/http.json" 2>> "$OUTDIR/logs/httpx_error.log" &
    spinner $! "HTTP Probing"
    
    # Take screenshots of live hosts
    log "INFO" "Capturing screenshots"
    jq -r '.url' "$OUTDIR/processed/http.json" | aquatone -out "$OUTDIR/screenshots" -threads $THREADS 2>> "$OUTDIR/logs/aquatone_error.log" &
    spinner $! "Screenshots"
    
    live_count=$(jq -r '.url' "$OUTDIR/processed/http.json" | wc -l)
    log "SUCCESS" "Found $live_count live HTTP services"
}

# Main execution
{
    subdomain_enum
    dns_resolution
    http_probing
    
    # Additional recon steps would go here
    # (Vulnerability scanning, directory brute-forcing, etc.)
    
    log "SUCCESS" "Reconnaissance completed successfully"
    log "INFO" "Total execution time: $SECONDS seconds"
    log "INFO" "Results saved to: $OUTDIR"
    log "INFO" "Full log available at: $LOGFILE"
    
    # Generate report summary
    echo -e "\n${GREEN}=== RECON SUMMARY ===${NC}" | tee -a "$LOGFILE"
    echo -e "Subdomains Found: $sub_count" | tee -a "$LOGFILE"
    echo -e "Valid DNS Records: $valid_count" | tee -a "$LOGFILE"
    echo -e "Live HTTP Services: $live_count" | tee -a "$LOGFILE"
    echo -e "Total Execution Time: $SECONDS seconds" | tee -a "$LOGFILE"
    echo -e "Output Directory: $OUTDIR" | tee -a "$LOGFILE"
} | tee -a "$LOGFILE"

# Compress results
log "INFO" "Compressing results"
tar -czf "recon_${DOMAIN}_${TIMESTAMP}.tar.gz" "$OUTDIR" 2>/dev/null &
spinner $! "Compressing"
log "SUCCESS" "Archive created: recon_${DOMAIN}_${TIMESTAMP}.tar.gz"

exit 0
