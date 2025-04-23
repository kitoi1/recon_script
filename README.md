#!/bin/bash

# Enhanced Recon Script v2.0 with Cool Interface
# Features: Parallel processing, additional tools, better error handling, JSON outputs, and awesome UI

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
 |  _ \\_   _|  _ \\| ____|  _ \\| | | / ___| ____|  _ \\ 
 | |_) || | | |_) |  _| | | | | | | \\___ \\  _| | | | |
 |  _ < | | |  _ <| |___| |_| | |_| |___) | |___| |_| |
 |_| \\_\\|_| |_| \\_\\_____|____/ \\___/|____/|_____|____/ 
${NC}"
echo -e "${YELLOW}                     Enhanced Reconnaissance Suite v2.0${NC}"
echo -e "${MAGENTA}--------------------------------------------------------${NC}"

# Check if domain is provided
if [ -z "$1" ]; then
    echo -e "${RED}[!] Error: No domain specified${NC}"
    echo -e "${YELLOW}Usage: $0 <domain>${NC}"
    exit 1
fi

DOMAIN=$1
OUTDIR=recon/$DOMAIN
TOOLS_DIR=/opt/tools
THREADS=100
TIMEOUT=10

# Banner
function show_banner() {
    clear
    echo -e "${CYAN}"
    echo "  ___________________________________________________________"
    echo " /                                                           \\"
    echo "|    Starting reconnaissance on: ${YELLOW}$DOMAIN${CYAN}                  |"
    echo " \\___________________________________________________________/"
    echo -e "${NC}"
}

# Progress spinner
function spinner() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Setup environment
show_banner
echo -e "${BLUE}[*]${NC} Initializing reconnaissance environment at $(date)"
mkdir -p $OUTDIR/{raw,processed} 2>/dev/null &
spinner

# 1. Subdomain Enumeration (Parallel)
echo -e "\n${GREEN}[+]${NC} Running ${MAGENTA}Subdomain Discovery${NC} (Parallel Mode)"
{
    echo -e "${CYAN}  - Running Subfinder${NC}" >&2
    subfinder -d $DOMAIN -silent -t $THREADS -timeout $TIMEOUT -o $OUTDIR/raw/subfinder.txt
    
    echo -e "${CYAN}  - Running Assetfinder${NC}" >&2
    assetfinder --subs-only $DOMAIN > $OUTDIR/raw/assetfinder.txt
    
    echo -e "${CYAN}  - Running Amass${NC}" >&2
    amass enum -passive -d $DOMAIN -timeout $TIMEOUT -o $OUTDIR/raw/amass.txt
    
    echo -e "${CYAN}  - Running Findomain${NC}" >&2
    findomain -t $DOMAIN -r -u $OUTDIR/raw/findomain.txt
} |& tee $OUTDIR/subdomain_logs.txt &
spinner

# 2. Aggregate and Deduplicate
echo -e "\n${GREEN}[+]${NC} Processing and Deduplicating Subdomains"
cat $OUTDIR/raw/*.txt | sort -u | anew $OUTDIR/subs.txt 2>/dev/null &
spinner
sub_count=$(wc -l < $OUTDIR/subs.txt)
echo -e "${YELLOW}[*]${NC} Found ${GREEN}$sub_count${NC} unique subdomains"

# 3. DNS Resolution (Fast)
echo -e "\n${GREEN}[+]${NC} Performing ${MAGENTA}DNS Resolution${NC} (Fast Mode)"
dnsx -l $OUTDIR/subs.txt -silent -a -aaaa -cname -mx -txt -ptr -resp \
     -retry 3 -threads $THREADS -json -o $OUTDIR/processed/dns.json 2>/dev/null &
spinner

# 4. HTTP Probing (Smart)
echo -e "\n${GREEN}[+]${NC} Probing ${MAGENTA}HTTP Services${NC}
