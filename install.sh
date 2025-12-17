#!/bin/bash
#
# L8 OS Install Script
# Installs Granville (inference kernel) + McCoy (agent framework)
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/layer8-dev/granville/main/install.sh | bash
#
# Or with options:
#   curl -sSL ... | bash -s -- --no-model    # Skip model download
#   curl -sSL ... | bash -s -- --no-mccoy    # Skip McCoy install
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Config
GRANVILLE_VERSION="${GRANVILLE_VERSION:-latest}"
GITHUB_REPO="rjpruitt16/granville"
MCCOY_REPO="rjpruitt16/mccoy"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
MODEL_DIR="$HOME/.granville/models"
DEFAULT_MODEL_URL="https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"
DEFAULT_MODEL_NAME="tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"

# Options
SKIP_MODEL=false
SKIP_MCCOY=false

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-model)
            SKIP_MODEL=true
            shift
            ;;
        --no-mccoy)
            SKIP_MCCOY=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}"
echo "  ██╗      █████╗      ██████╗ ███████╗"
echo "  ██║     ██╔══██╗    ██╔═══██╗██╔════╝"
echo "  ██║     ╚█████╔╝    ██║   ██║███████╗"
echo "  ██║     ██╔══██╗    ██║   ██║╚════██║"
echo "  ███████╗╚█████╔╝    ╚██████╔╝███████║"
echo "  ╚══════╝ ╚════╝      ╚═════╝ ╚══════╝"
echo -e "${NC}"
echo "  Local AI OS - Granville + McCoy"
echo ""

# Detect OS and architecture
detect_platform() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "$OS" in
        Linux)
            OS="linux"
            ;;
        Darwin)
            OS="macos"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            OS="windows"
            ;;
        *)
            echo -e "${RED}Unsupported OS: $OS${NC}"
            exit 1
            ;;
    esac

    case "$ARCH" in
        x86_64|amd64)
            ARCH="x86_64"
            ;;
        arm64|aarch64)
            ARCH="aarch64"
            ;;
        *)
            echo -e "${RED}Unsupported architecture: $ARCH${NC}"
            exit 1
            ;;
    esac

    PLATFORM="${OS}-${ARCH}"
    echo -e "${GREEN}Detected platform: ${PLATFORM}${NC}"
}

# Check dependencies
check_deps() {
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}curl is required but not installed.${NC}"
        exit 1
    fi

    if ! $SKIP_MCCOY; then
        if ! command -v python3 &> /dev/null; then
            echo -e "${YELLOW}Warning: python3 not found. Skipping McCoy install.${NC}"
            SKIP_MCCOY=true
        fi
        if ! command -v pip3 &> /dev/null && ! command -v pip &> /dev/null; then
            echo -e "${YELLOW}Warning: pip not found. Skipping McCoy install.${NC}"
            SKIP_MCCOY=true
        fi
    fi
}

# Download Granville binary
install_granville() {
    echo -e "\n${BLUE}[1/3] Installing Granville...${NC}"

    # Construct download URL
    if [ "$GRANVILLE_VERSION" = "latest" ]; then
        DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/granville-${PLATFORM}"
    else
        DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${GRANVILLE_VERSION}/granville-${PLATFORM}"
    fi

    # Add .exe for Windows
    if [ "$OS" = "windows" ]; then
        DOWNLOAD_URL="${DOWNLOAD_URL}.exe"
        BINARY_NAME="granville.exe"
    else
        BINARY_NAME="granville"
    fi

    echo "Downloading from: $DOWNLOAD_URL"

    # Check if we need sudo
    if [ -w "$INSTALL_DIR" ]; then
        SUDO=""
    else
        SUDO="sudo"
        echo -e "${YELLOW}Need sudo to install to ${INSTALL_DIR}${NC}"
    fi

    # Download
    TMP_FILE=$(mktemp)
    if curl -fsSL "$DOWNLOAD_URL" -o "$TMP_FILE"; then
        $SUDO mv "$TMP_FILE" "${INSTALL_DIR}/${BINARY_NAME}"
        $SUDO chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
        echo -e "${GREEN}Granville installed to ${INSTALL_DIR}/${BINARY_NAME}${NC}"
    else
        echo -e "${RED}Failed to download Granville.${NC}"
        echo -e "${YELLOW}Falling back to build from source...${NC}"
        install_granville_source
    fi
}

# Fallback: build from source
install_granville_source() {
    if ! command -v zig &> /dev/null; then
        echo -e "${RED}Zig not found. Cannot build from source.${NC}"
        echo "Install Zig from https://ziglang.org/download/"
        exit 1
    fi

    echo "Cloning and building Granville..."
    TMP_DIR=$(mktemp -d)
    git clone "https://github.com/${GITHUB_REPO}.git" "$TMP_DIR"
    cd "$TMP_DIR"
    zig build -Doptimize=ReleaseFast

    if [ -w "$INSTALL_DIR" ]; then
        cp zig-out/bin/granville "${INSTALL_DIR}/"
    else
        sudo cp zig-out/bin/granville "${INSTALL_DIR}/"
    fi

    cd -
    rm -rf "$TMP_DIR"
    echo -e "${GREEN}Granville built and installed.${NC}"
}

# Install default driver
install_driver() {
    echo -e "\n${BLUE}[2/3] Installing granville-llama driver...${NC}"

    if command -v granville &> /dev/null; then
        granville driver install granville-llama || echo -e "${YELLOW}Driver install skipped (may already exist)${NC}"
    else
        "${INSTALL_DIR}/granville" driver install granville-llama || echo -e "${YELLOW}Driver install skipped${NC}"
    fi
}

# Download default model
download_model() {
    if $SKIP_MODEL; then
        echo -e "\n${YELLOW}[2/3] Skipping model download (--no-model)${NC}"
        return
    fi

    echo -e "\n${BLUE}[2/3] Downloading TinyLlama model (~640MB)...${NC}"

    mkdir -p "$MODEL_DIR"

    if [ -f "${MODEL_DIR}/${DEFAULT_MODEL_NAME}" ]; then
        echo -e "${GREEN}Model already exists at ${MODEL_DIR}/${DEFAULT_MODEL_NAME}${NC}"
        return
    fi

    echo "This may take a few minutes..."
    if curl -fSL "$DEFAULT_MODEL_URL" -o "${MODEL_DIR}/${DEFAULT_MODEL_NAME}" --progress-bar; then
        echo -e "${GREEN}Model downloaded to ${MODEL_DIR}/${DEFAULT_MODEL_NAME}${NC}"
    else
        echo -e "${YELLOW}Model download failed. You can download manually later:${NC}"
        echo "  granville download $DEFAULT_MODEL_URL"
    fi
}

# Install McCoy
install_mccoy() {
    if $SKIP_MCCOY; then
        echo -e "\n${YELLOW}[3/3] Skipping McCoy install (--no-mccoy)${NC}"
        return
    fi

    echo -e "\n${BLUE}[3/3] Installing McCoy (Python agent framework)...${NC}"

    # Determine pip command
    if command -v pip3 &> /dev/null; then
        PIP="pip3"
    else
        PIP="pip"
    fi

    # Try PyPI first, fall back to git
    if $PIP install mccoy 2>/dev/null; then
        echo -e "${GREEN}McCoy installed from PyPI${NC}"
    else
        echo "Installing McCoy from GitHub..."
        $PIP install "git+https://github.com/${MCCOY_REPO}.git" || {
            echo -e "${YELLOW}McCoy install failed. Install manually:${NC}"
            echo "  pip install git+https://github.com/${MCCOY_REPO}.git"
        }
    fi
}

# Print next steps
print_next_steps() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Installation Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Quick Start:"
    echo ""
    echo "  # Terminal 1: Start the inference server"
    echo -e "  ${BLUE}granville serve ~/.granville/models/${DEFAULT_MODEL_NAME}${NC}"
    echo ""
    echo "  # Terminal 2: Chat with your local AI"
    echo -e "  ${BLUE}mccoy chat${NC}"
    echo ""
    echo "Or use Granville directly:"
    echo ""
    echo "  granville --help"
    echo "  granville driver list"
    echo ""
    echo "Download more models:"
    echo "  granville download <huggingface-url>"
    echo ""
    echo -e "${YELLOW}Note: For best results, use a 7B+ model.${NC}"
    echo "  Recommended: Llama 3.2 3B, Mistral 7B, or Qwen 2.5 7B"
    echo ""
}

# Main
main() {
    detect_platform
    check_deps
    install_granville
    install_driver
    download_model
    install_mccoy
    print_next_steps
}

main
