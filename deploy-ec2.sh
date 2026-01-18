#!/bin/bash
# EC2 deployment trigger - syncs scripts and runs deployment on EC2
# usage: ./deploy-ec2.sh
# [deploy-ec2.sh] connect ssh & copies deploy.sh and pull.sh to ec2 -> [deploy.sh (on ec2)] stops services and runs pull.sh and starts services -> [pull.sh (on ec2)] pulls code with gitencrypt

# used for automating deployment to prod with encrypted repositories (gcrypt), otherwise we use ansible & teraform
# see: https://archclx.medium.com/enforcing-gpg-encryption-in-github-using-git-remote-gcrypt-9fc289092b25


set -e

# get script directory - scripts are in same directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

echo -e "${BLUE}EC2 Deployment${RESET}"
echo ""

# ec2 deployment configuration
# set these in your environment (~/.bashrc or ~/.zshrc) or edit defaults here
EC2_HOST="${EC2_HOST:-}"
EC2_USER="${EC2_USER:-ubuntu}"
EC2_KEY="${EC2_KEY:-$HOME/.ssh/ec2-prod.pem}"
EC2_APP_DIR="${EC2_APP_DIR:-/home/ubuntu/backend}"

if [ -z "$EC2_HOST" ]; then
  echo -e "${RED}EC2_HOST not set.${RESET}"
  echo ""
  echo "   To configure, add to ~/.zshrc or ~/.bashrc:"
  echo "   ────────────────────────────────────────────────────────"
  echo "   export EC2_HOST=\"your-ec2-public-ip\""
  echo "   export EC2_KEY=\"~/.ssh/ec2-prod.pem\""
  echo "   export EC2_USER=\"ubuntu\"  # optional"
  echo "   export EC2_APP_DIR=\"/home/ubuntu/backend\"  # optional"
  echo "   ────────────────────────────────────────────────────────"
  echo ""
  exit 1
fi

echo -e "${YELLOW}Configuration:${RESET}"
echo "  Host: $EC2_USER@$EC2_HOST"
echo "  Key: $EC2_KEY"
echo "  App Dir: $EC2_APP_DIR"
echo ""

if [ ! -f "$EC2_KEY" ]; then
  echo -e "${RED}SSH key not found: $EC2_KEY${RESET}"
  echo ""
  echo "   To fix, place your EC2 .pem key and set permissions:"
  echo "   ────────────────────────────────────────────────────────"
  echo "   mv /path/to/your-key.pem ~/.ssh/ec2-prod.pem"
  echo "   chmod 600 ~/.ssh/ec2-prod.pem"
  echo ""
  echo "   Or set a custom path:"
  echo "   export EC2_KEY=\"/path/to/your-key.pem\""
  echo "   ────────────────────────────────────────────────────────"
  exit 1
fi

# sync deployment scripts to ec2 first (prevents bootstrap paradox)
echo -e "${BLUE}Syncing deployment scripts to EC2...${RESET}"

# upload to /tmp first, then move with sudo (handles permission issues)
PROD_BACKEND_DIR="$SCRIPT_DIR/../prod/backend"

read -p "$(echo -e ${YELLOW}"Do you want to sync the .git directory? (y/n): "${RESET})" SYNC_GIT
if [[ "$SYNC_GIT" =~ ^[Yy]$ ]] && [ -d "$PROD_BACKEND_DIR/.git" ]; then
  echo -e "${BLUE}Syncing .git directory...${RESET}"
  tar -czf /tmp/prod-git.tar.gz -C "$PROD_BACKEND_DIR" .git
  scp -i "$EC2_KEY" -o StrictHostKeyChecking=no /tmp/prod-git.tar.gz "$EC2_USER@$EC2_HOST:/tmp/prod-git.tar.gz"
  ssh -i "$EC2_KEY" -o StrictHostKeyChecking=no "$EC2_USER@$EC2_HOST" "sudo rm -rf $EC2_APP_DIR/.git && sudo tar -xzf /tmp/prod-git.tar.gz -C $EC2_APP_DIR && sudo chown -R $EC2_USER:$EC2_USER $EC2_APP_DIR/.git"
  rm /tmp/prod-git.tar.gz
  echo -e "${GREEN}.git directory synced${RESET}"
fi

read -p "$(echo -e ${YELLOW}"Do you want to sync deployment scripts (deploy.sh, pull.sh)? (y/n): "${RESET})" SYNC_SCRIPTS
if [[ "$SYNC_SCRIPTS" =~ ^[Yy]$ ]]; then
  if [ -f "$SCRIPT_DIR/deploy.sh" ]; then
    scp -i "$EC2_KEY" -o StrictHostKeyChecking=no "$SCRIPT_DIR/deploy.sh" "$EC2_USER@$EC2_HOST:/tmp/deploy.sh"
    ssh -i "$EC2_KEY" -o StrictHostKeyChecking=no "$EC2_USER@$EC2_HOST" "sudo mv /tmp/deploy.sh $EC2_APP_DIR/deploy.sh && sudo chmod +x $EC2_APP_DIR/deploy.sh"
    [ $? -eq 0 ] && echo -e "${GREEN}deploy.sh${RESET}" || echo -e "${RED}deploy.sh failed${RESET}"
  fi

  if [ -f "$SCRIPT_DIR/pull.sh" ]; then 
    scp -i "$EC2_KEY" -o StrictHostKeyChecking=no "$SCRIPT_DIR/pull.sh" "$EC2_USER@$EC2_HOST:/tmp/pull.sh"
    ssh -i "$EC2_KEY" -o StrictHostKeyChecking=no "$EC2_USER@$EC2_HOST" "sudo mv /tmp/pull.sh $EC2_APP_DIR/pull.sh && sudo chmod +x $EC2_APP_DIR/pull.sh"
    [ $? -eq 0 ] && echo -e "${GREEN}pull.sh${RESET}" || echo -e "${RED}pull.sh failed${RESET}"
  fi
else
  echo -e "${BLUE}Skipping script sync...${RESET}"
fi

echo ""
echo -e "${BLUE}Running full deployment (stop services → pull → restart)...${RESET}"
echo ""
ssh -t -i "$EC2_KEY" -o StrictHostKeyChecking=no "$EC2_USER@$EC2_HOST" "export TERM=xterm && cd $EC2_APP_DIR && ls && sudo chmod +x deploy.sh && ./deploy.sh"
DEPLOY_STATUS=$?

if [ $DEPLOY_STATUS -eq 0 ]; then
  echo ""
  echo -e "${GREEN}EC2 deployment successful!${RESET}"
  echo ""
  echo -e "${YELLOW}Checking Remote Logs (Caddy):${RESET}"
  ssh -t -i "$EC2_KEY" -o StrictHostKeyChecking=no "$EC2_USER@$EC2_HOST" "export TERM=xterm; sudo tmux list-sessions 2>&1 | grep caddy; sudo tmux capture-pane -pt caddy || echo -e '${RED}Failed to capture caddy logs${RESET}'"
  echo ""
  echo -e "${YELLOW}Checking Remote Logs (Django):${RESET}"
  ssh -t -i "$EC2_KEY" -o StrictHostKeyChecking=no "$EC2_USER@$EC2_HOST" "export TERM=xterm; sudo tmux list-sessions 2>&1 | grep django; sudo tmux capture-pane -pt django || echo -e '${RED}Failed to capture django logs${RESET}'"
  echo ""
else
  echo ""
  echo -e "${RED}[X] EC2 deployment failed. Check the output above.${RESET}"
  exit 1
fi
