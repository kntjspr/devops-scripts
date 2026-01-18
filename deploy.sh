#!/bin/bash
# EC2 deployment script - automates the full update cycle
# stops services -> pulls code -> restarts services


set -e
# set colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

# set xterm if missing/incompatible
if [ -z "$TERM" ] || [ "$TERM" = "dumb" ] || [[ "$TERM" == *"kitty"* ]]; then
  export TERM=xterm
fi

# set xterm on bashrc for tmux & openpgp compatibility
if ! grep -q "Auto-fix TERM" ~/.bashrc; then
  echo -e "${YELLOW}Adding persistent TERM fix to ~/.bashrc...${RESET}"
  cat << 'EOF' >> ~/.bashrc

# auto-fix TERM for tmux/compatibility
if [ -z "$TERM" ] || [ "$TERM" = "dumb" ] || [[ "$TERM" == *"kitty"* ]]; then
  export TERM=xterm
fi
EOF
  echo -e "${GREEN}Added. It will take effect on next login.${RESET}"
fi

BACKEND_DIR="${BACKEND_DIR:-/home/ubuntu/backend}"
CADDY_SESSION="caddy"
DJANGO_SESSION="django"
CADDY_CONFIG="${CADDY_CONFIG:-$BACKEND_DIR/Caddyfile}"

echo -e "${BLUE}EC2 Deployment Script${RESET}"

# step 1: pull latest code
echo -e "${BLUE}Pulling latest code...${RESET}"
cd "$BACKEND_DIR"
./pull.sh

# step 2: stop caddy
echo -e "${BLUE}Stopping Caddy...${RESET}"
if sudo tmux has-session -t "$CADDY_SESSION" 2>/dev/null; then
  sudo tmux send-keys -t "$CADDY_SESSION" C-c
  sleep 2
  # kill session to ensure fresh start and fresh logs
  sudo tmux kill-session -t "$CADDY_SESSION" 2>/dev/null || true
  echo -e "${GREEN}Caddy stopped and session cleared${RESET}"
else
  echo -e "${YELLOW}Caddy session not found, skipping${RESET}"
fi

# step 3: stop django
echo -e "${BLUE}Stopping Django...${RESET}"
if sudo tmux has-session -t "$DJANGO_SESSION" 2>/dev/null; then
  sudo tmux send-keys -t "$DJANGO_SESSION" C-c
  sleep 2
  sudo tmux kill-session -t "$DJANGO_SESSION" 2>/dev/null || true
  echo -e "${GREEN}Django stopped and session cleared${RESET}"
else
  echo -e "${YELLOW}Django session not found, skipping${RESET}"
fi

# step 4: start caddy
echo -e "${BLUE}Starting Caddy...${RESET}"
sudo tmux new-session -d -s "$CADDY_SESSION" "echo \"User: \$(whoami)\"; echo 'Starting Caddy session...'; caddy run --config \"$CADDY_CONFIG\"; echo 'Caddy exited with status $?'; bash"
echo -e "${GREEN}Caddy session created and started${RESET}"

# step 5: start django
echo -e "${BLUE}Starting Django...${RESET}"
sudo tmux new-session -d -s "$DJANGO_SESSION" "echo \"User: \$(whoami)\"; echo 'Starting Django session...'; cd \"$BACKEND_DIR\" && .venv/bin/python3 serve_prod.py; echo 'Django exited with status $?'; bash"
echo -e "${GREEN}Django session created and started${RESET}"

echo ""
echo -e "${GREEN}Deployment Complete!${RESET}"
echo ""
echo "check status:"
echo "  sudo tmux attach -t caddy   # view caddy logs"
echo "  sudo tmux attach -t django  # view django logs"
echo "  (Ctrl+B, D to detach)"
