#!/bin/bash

# Enhanced Recon Script v3.0
# Features: Modular structure, better error handling, parallel processing, and comprehensive enumeration

# Input Validation
if [ -z "$1" ]; then
    echo "Usage: $0 <domain>"
    exit 1
fi

# Variables
DOMAIN=$1
OUTDIR="recon/$DOMAIN"
TOOLS_DIR="/opt/tools"
THREADS=100
TIMEOUT=10
LOGFILE="$OUTDIR/recon.log"

# Setup Output Directory
mkdir -p $OUTDIR/{raw,processed,screenshots}
touch $LOGFILE

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOGFILE
}

log "[*] Starting enhanced recon for $DOMAIN"

# Function to check if required tools are installed
check_tool() {
    if ! command -v $1 &> /dev/null; then
        log "[-] Error: $1 is not installed. Please install it before running the script."
        exit 1
    fi
}

# Check Required Tools
TOOLS=("subfinder" "assetfinder" "amass" "findomain" "dnsx" "httpx" "nuclei" "gau" "jq" "anew" "aquatone" "cloud_enum")
for tool in "${TOOLS[@]}"; do
    check_tool $tool
done

# 1. Subdomain Enumeration (Parallel)
log "[+] Running subdomain discovery"
{
    subfinder -d $DOMAIN -silent -t $THREADS -timeout $TIMEOUT -o $OUTDIR/raw/subfinder.txt
    assetfinder --subs-only $DOMAIN > $OUTDIR/raw/assetfinder.txt
    amass enum -passive -d $DOMAIN -timeout $TIMEOUT -o $OUTDIR/raw/amass.txt
    findomain -t $DOMAIN -r -u $OUTDIR/raw/findomain.txt
} |& tee -a $LOGFILE

# 2. Aggregate and Deduplicate
log "[+] Aggregating and deduplicating subdomains"
cat $OUTDIR/raw/*.txt | sort -u | anew $OUTDIR/subs.txt
log "[*] Found $(wc -l < $OUTDIR/subs.txt) unique subdomains"

# 3. DNS Resolution
log "[+] Resolving DNS records"
dnsx -l $OUTDIR/subs.txt -silent -a -aaaa -cname -mx -txt -ptr -resp \
     -retry 3 -threads $THREADS -json -o $OUTDIR/processed/dns.json

# 4. HTTP Probing
log "[+] Probing HTTP services"
cat $OUTDIR/subs.txt | httpx -silent -title -status-code -tech-detect \
    -favicon -http2 -json -threads $THREADS -timeout $TIMEOUT \
    -o $OUTDIR/processed/http.json

# 5. Vulnerability Scanning
log "[+] Running vulnerability scanning with nuclei"
{
    # Fast CVE scan
    cat $OUTDIR/processed/http.json | jq -r .url | nuclei -silent -t $TOOLS_DIR/nuclei-templates/cves/ -rl 50 \
        -o $OUTDIR/nuclei_cves.txt

    # Full scan for critical findings
    cat $OUTDIR/processed/http.json | jq -r 'select(.status_code | tonumber < 400) | .url' \
        | nuclei -silent -t $TOOLS_DIR/nuclei-templates/ -severity medium,high,critical -rl 20 \
        -o $OUTDIR/nuclei_full.txt
} &

# 6. Additional Enumeration
log "[+] Running additional enumeration"
{
    gau --subs $DOMAIN | anew $OUTDIR/processed/wayback_urls.txt
    [ -f "$HOME/.config/github_tokens" ] && \
        github-subdomains -d $DOMAIN -t $(cat $HOME/.config/github_tokens) -o $OUTDIR/processed/github_subs.txt
    cloud_enum -k $DOMAIN -l $OUTDIR/processed/cloud_assets.txt
} |& tee -a $LOGFILE

# 7. Visual Recon
if command -v aquatone &> /dev/null; then
    log "[+] Capturing screenshots with Aquatone"
    cat $OUTDIR/processed/http.json | jq -r .url | aquatone -threads $THREADS \
        -out $OUTDIR/screenshot -silent
else
    log "[-] Aquatone not found. Skipping screenshots."
fi

# 8. Generate HTML Report
log "[+] Generating HTML report"
if [ -f "$TOOLS_DIR/report_generator.py" ]; then
    python3 $TOOLS_DIR/report_generator.py -i $OUTDIR/processed -o $OUTDIR/report.html
else
    log "[-] Report generator script not found. Skipping report generation."
fi

# Completion Message
log "[✓] Enhanced recon completed"
log "[!] Results saved in $OUTDIR"
log "[!] Critical findings: $(grep -c 'high\|critical' $OUTDIR/nuclei_*.txt)"
