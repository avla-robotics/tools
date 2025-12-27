#!/usr/bin/env bash
set -euo pipefail

# Require args
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <config> <weights>"
  echo "  config  = config name"
  echo "  weights = gs://bucket/... or Git repo URL"
  exit 1
fi

config="$1"
weights="$2"

PROJECT_DIR="$HOME/project"
OPENPI_DIR="$PROJECT_DIR/openpi"
UV_BIN="$HOME/.local/bin/uv"

# ---- Logging setup (logger.sh) ----
LOGGER_URL="https://raw.githubusercontent.com/avla-robotics/tools/refs/heads/main/logger.sh"
LOG_DIR="$PROJECT_DIR/logs"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
LOGFILE="$LOG_DIR/${RUN_ID}.log"
LOG_PORT="${LOG_PORT:-8080}"

mkdir -p "$LOG_DIR"

LOGGER_PATH="$(mktemp)"
trap 'rm -f "$LOGGER_PATH"' EXIT
curl -fsSL "$LOGGER_URL" -o "$LOGGER_PATH"
chmod +x "$LOGGER_PATH"

# Everything below is piped (stdout+stderr) into logger.sh
{
  echo "run_id=$RUN_ID"
  echo "logfile=$LOGFILE"
  echo "log_port=$LOG_PORT"
  echo "config=$config"
  echo "weights=$weights"
  echo "----"

  # If project exists, just run the Python script
  if [ -d "$OPENPI_DIR" ]; then
    echo "Project already exists. Skipping setup..."
    cd "$OPENPI_DIR"
  else
    echo "Project not found. Performing full setup..."

    # Always install git-lfs for handling large model files
    echo "Installing git-lfs..."
    apt-get update -qq && apt-get install -y -qq git-lfs
    git lfs install

    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"

    # If this is a repo, clone it and update the weights path.
    if [[ "$weights" != gs://* ]]; then
      echo "Cloning weights repository with LFS support..."
      git clone "$weights" weights
      cd weights
      git lfs pull
      cd ..
      weights="$PROJECT_DIR/weights"
      echo "Cloned weights repo -> $weights"
    fi

    git clone --recurse-submodules https://github.com/Physical-Intelligence/openpi.git
    cd openpi

    # Install uv if not already installed
    if [ ! -f "$UV_BIN" ]; then
      echo "Installing uv..."
      curl -LsSf https://astral.sh/uv/install.sh | sh
    fi

    "$UV_BIN" sync
    "$UV_BIN" pip install tyro
    "$UV_BIN" pip install transformers==4.53.2
    cp -r ./src/openpi/models_pytorch/transformers_replace/* .venv/lib/python3.11/site-packages/transformers/

    # Download the weight conversion script
    echo "Downloading weight conversion script..."
    curl -fsSL "https://raw.githubusercontent.com/avla-robotics/tools/refs/heads/main/convert_lerobot_weights.py" -o /tmp/convert_lerobot_weights.py
  fi

  # Check if weights need conversion and convert if necessary
  if [ -f "$weights/model.safetensors" ]; then
    echo "Checking if weights need conversion..."
    # Try to detect if weights have 'model.' prefix by checking a few common keys
    if .venv/bin/python3 -c "
import safetensors
try:
    with safetensors.safe_open('$weights/model.safetensors', framework='pt') as f:
        keys = list(f.keys())[:10]  # Check first 10 keys
        has_model_prefix = any(k.startswith('model.') for k in keys)
        if has_model_prefix:
            print('NEEDS_CONVERSION')
        else:
            print('ALREADY_CONVERTED')
except Exception as e:
    print(f'ERROR: {e}')
" | grep -q "NEEDS_CONVERSION"; then
      echo "Weights need conversion. Converting in-place..."
      .venv/bin/python3 /tmp/convert_lerobot_weights.py --input_path "$weights"
      echo "Weight conversion completed."
    else
      echo "Weights are already in OpenPI format."
    fi
  fi

  # Run the Python policy server (line-buffered for real-time logs)
  echo "Starting policy server..."
  stdbuf -oL -eL .venv/bin/python3 scripts/serve_policy.py --port 8000 policy:checkpoint \
    --policy.config="$config" \
    --policy.dir="$weights"

} 2>&1 | bash "$LOGGER_PATH" --logfile "$LOGFILE" --port "$LOG_PORT"
