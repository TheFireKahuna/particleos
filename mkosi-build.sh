#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# Modern Mkosi Build Configuration Script
# A fluent, validating interface for building systemd-centric images with mkosi
# ══════════════════════════════════════════════════════════════════════════════

set -e # Exit immediately if a command exits with a non-zero status

# ═══════════════════════════ Error Handling ═════════════════════════════════
# Clean up on exit
trap 'cleanup' EXIT INT TERM

# ═════════════════════════════ Helper Functions ═════════════════════════════
print_header() {
  echo -e "\n${BLUE}${BOLD}$1${RESET}"
  echo -e "${BLUE}${BOLD}$(printf '═%.0s' $(seq 1 ${#1}))${RESET}"
}

print_info() {
  echo -e "${CYAN}${BOLD}→${RESET} $1"
}

print_success() {
  echo -e "${GREEN}${BOLD}✓${RESET} $1"
}

print_warning() {
  echo -e "${YELLOW}${BOLD}!${RESET} $1"
}

print_error() {
  echo -e "${RED}${BOLD}✗${RESET} $1" >&2
}

# Check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Execute command with error handling
safe_exec() {
  local cmd="$1"
  local error_msg="${2:-Command failed: $cmd}"
  
  if ! eval "$cmd"; then
    print_error "$error_msg"
    return 1
  fi
  return 0
}


# ═══════════════════════════ Color & Formatting ═════════════════════════════
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

# ════════════════════════════ Configuration ══════════════════════════════════
# Directory variables
readonly MKOSI_DIR="mkosi"
readonly SANDBOX_DIR="mkosi.sandbox"
readonly SKELETON_DIR="mkosi.skeleton"
#readonly EXTRA_DIR="mkosi.extra"

# Default settings
DEFAULT_ARCHITECTURE="$(uname -m)"
DEFAULT_DISTRIBUTION="fedora"
DEFAULT_PROFILE=""  # No profile by default

ARCHITECTURE="$DEFAULT_ARCHITECTURE"
DISTRIBUTION="$DEFAULT_DISTRIBUTION"
PROFILE="$DEFAULT_PROFILE"
ROOT_PASSWORD=""
DEBUG_MODE=false
INTERACTIVE=false  # Interactive mode is off if args are provided
CLEAN_MKOSI="-f"
FORCE_CONFIRM=false

# New variable: whether to use openSUSE packages for enhanced systemd dev builds.
# This will be set interactively or via command-line flag.
USE_OPENSUSE=true

# Available options without hardcoded default text:
VALID_ARCHITECTURES=(
  "x86_64:64-bit Intel/AMD architecture"
  "aarch64:64-bit ARM architecture"
)

VALID_DISTRIBUTIONS=(
  "fedora:Fedora Linux"
  "arch:Arch Linux"
  "debian:Debian Linux"
)

VALID_PROFILES=(
  "desktop,gnome:GNOME Desktop profile"
  "desktop,kde:KDE Desktop profile"
  "desktop:Desktop base profile"
)

# ════════════════════════════ Cleanup functions ══════════════════════════════

# Cleanup function - only remove temporary files we created during this run
cleanup() {
  print_info "Cleaning up temporary files..."
  
  # If we created a temporary root password file, remove it
  if [[ -f "mkosi.rootpw" ]] && [[ "$ROOT_PASSWORD" == "" ]]; then
    rm -f "mkosi.rootpw"
  fi
  
  print_success "Cleanup completed"
}

# New helper: Detect default for openSUSE packages based on local config file
detect_default_opensuse() {
  if [[ -f "mkosi.local.conf" ]] && grep -q "^ExtraSearchPaths=" "mkosi.local.conf"; then
    echo "no"
  else
    echo "yes"
  fi
}

# Add this function to clean up openSUSE repo configuration files in a less destructive way.
cleanup_opensuse_repos() {
  # List of known openSUSE repository configuration files.
  local repos=(
    "/etc/pacman.d/10-openSUSE.conf"
    "/usr/share/pacman/keyrings/system_systemd_Arch.gpg"
    "/usr/share/pacman/keyrings/system_systemd_Arch-trusted"
    "/etc/yum.repos.d/system:systemd.repo"
    "/etc/apt/sources.list.d/systemd-opensuse.sources"
    "/etc/apt/keyrings/systemd-opensuse.gpg"
    "/etc/apt/keyrings/systemd-opensuse.gpg.asc"
  )
  
  # Remove files from all target directories
  for dir in "$SANDBOX_DIR" "$SKELETON_DIR"; do  # "$EXTRA_DIR" 
    for file in "${repos[@]}"; do
      local full_path="${dir}${file}"
      if [[ -e "$full_path" ]]; then
        rm -f "$full_path"
        print_info "Removed $full_path"
      fi
    done
  done
}

# Clean up only files associated with distributions that are not currently selected
cleanup_other_distributions() {
  print_info "Cleaning up repository files from other distributions..."
  
  # Define which files belong to each distribution
  declare -A arch_files=(
    ["pacman_conf"]="/etc/pacman.d/10-openSUSE.conf"
    ["keyring"]="/usr/share/pacman/keyrings/system_systemd_Arch.gpg"
    ["trusted"]="/usr/share/pacman/keyrings/system_systemd_Arch-trusted"
  )
  
  declare -A fedora_files=(
    ["repo"]="/etc/yum.repos.d/system:systemd.repo"
  )
  
  declare -A debian_files=(
    ["sources"]="/etc/apt/sources.list.d/systemd-opensuse.sources"
    ["keyring"]="/etc/apt/keyrings/systemd-opensuse.gpg"
    ["keyring_asc"]="/etc/apt/keyrings/systemd-opensuse.gpg.asc"
  )
  
  # Build a list of files to clean based on the selected distribution
  local files_to_clean=()
  
  if [[ "$DISTRIBUTION" != "arch" ]]; then
    for file in "${arch_files[@]}"; do
      files_to_clean+=("$file")
    done
  fi
  
  if [[ "$DISTRIBUTION" != "fedora" ]]; then
    for file in "${fedora_files[@]}"; do
      files_to_clean+=("$file")
    done
  fi
  
  if [[ "$DISTRIBUTION" != "debian" ]]; then
    for file in "${debian_files[@]}"; do
      files_to_clean+=("$file")
    done
  fi
  
  # Remove files from all target directories
  for dir in "$SKELETON_DIR"; do # "$EXTRA_DIR"
    for file in "${files_to_clean[@]}"; do
      local full_path="${dir}${file}"
      if [[ -e "$full_path" ]]; then
        rm -f "$full_path"
        if [[ "$DEBUG_MODE" == true ]]; then
          print_info "Removed $full_path"
        fi
      fi
    done
  done
}

# Clean up empty directories only
clean_empty_directories() {
  local dir_paths=(
    "/etc/pacman.d"
    "/etc/apt/sources.list.d"
    "/etc/apt/trusted.gpg.d"
    "/etc/apt/keyrings"
    "/etc/yum.repos.d"
    "/usr/share/pacman/keyrings"
  )
  
  for base_dir in "$SKELETON_DIR"; do # "$EXTRA_DIR"
    for subdir in "${dir_paths[@]}"; do
      local dir="${base_dir}${subdir}"
      if [[ -d "$dir" ]] && [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
        rmdir "$dir" 2>/dev/null || true
        if [[ "$DEBUG_MODE" == true ]]; then
          print_info "Removed empty directory $dir"
        fi
      fi
    done
    
    # Only remove the base directory if it's empty and not the main target directory
    if [[ -d "$base_dir" ]] && [[ -z "$(ls -A "$base_dir" 2>/dev/null)" ]]; then
      rmdir "$base_dir" 2>/dev/null || true
      if [[ "$DEBUG_MODE" == true && $? -eq 0 ]]; then
        print_info "Removed empty directory $base_dir"
      fi
    fi
  done
}

# ════════════════════════════ Validation Functions ══════════════════════════
validate_architecture() {
  local input="$1"
  for entry in "${VALID_ARCHITECTURES[@]}"; do
    key="${entry%%:*}"
    if [[ "$input" == "$key" ]]; then
      return 0  # valid
    fi
  done
  print_error "Invalid architecture: $input"
  echo -e "  ${YELLOW}Valid architectures:${RESET}"
  for entry in "${VALID_ARCHITECTURES[@]}"; do
    key="${entry%%:*}"
    description="${entry#*:}"
    echo -e "    • ${BOLD}$key${RESET} - $description"
  done
  return 1
}

validate_distribution() {
  local dist="$1"
  local valid=1
  for entry in "${VALID_DISTRIBUTIONS[@]}"; do
    local key="${entry%%:*}"
    if [[ "$key" == "$dist" ]]; then
      valid=0
      break
    fi
  done

  if [[ $valid -ne 0 ]]; then
    print_error "Invalid distribution: $dist"
    echo -e "  ${YELLOW}Valid distributions:${RESET}"
    for entry in "${VALID_DISTRIBUTIONS[@]}"; do
      local key="${entry%%:*}"
      local desc="${entry#*:}"
      echo -e "    • ${BOLD}$key${RESET} - $desc"
    done
    return 1
  fi
  return 0
}

validate_profile() {
  local prof="$1"
  local valid=1
  for entry in "${VALID_PROFILES[@]}"; do
    local key="${entry%%:*}"
    if [[ "$key" == "$prof" ]]; then
      valid=0
      break
    fi
  done

  if [[ $valid -ne 0 ]]; then
    print_error "Invalid profile: $prof"
    echo -e "  ${YELLOW}Valid profiles:${RESET}"
    for entry in "${VALID_PROFILES[@]}"; do
      local key="${entry%%:*}"
      local desc="${entry#*:}"
      echo -e "    • ${BOLD}$key${RESET} - $desc"
    done

    # If running in non-interactive mode, offer to continue with default
    if [[ "$INTERACTIVE" == false ]]; then
      return 1
    fi

    # In interactive mode, ask if the user wants to continue with the default
    read -p "Continue with default profile (none)? [Y/n]: " answer
    if [[ "$answer" =~ ^[Nn]$ ]]; then
      return 1
    else
      print_warning "Using default profile (none)"
      PROFILE=""
      return 0
    fi
  fi
  return 0
}

# Check for required dependencies
check_dependencies() {
  local missing=0
  
  for cmd in git curl gpg; do
    if ! command_exists "$cmd"; then
      print_error "Required command not found: $cmd"
      missing=1
    fi
  done
  
  if [[ $missing -eq 1 ]]; then
    print_error "Please install the missing dependencies and try again"
    exit 1
  fi
}

# ════════════════════════════ Setup Functions ═══════════════════════════════

setup_mkosi() {
  print_header "Setting up mkosi"
  
  # Ensure a current mkosi is used for builds
  if [[ ! -d "$MKOSI_DIR" ]]; then
    print_info "Cloning mkosi repository..."
    if ! git clone https://github.com/systemd/mkosi "$MKOSI_DIR"; then
      print_error "Failed to clone mkosi repository"
      exit 1
    fi
    print_success "Repository cloned successfully"
  else
    print_info "Updating existing mkosi repository..."
    if ! (cd "$MKOSI_DIR" && git pull); then
      print_warning "Failed to update mkosi repository, continuing with existing version"
    else
      print_success "Repository updated successfully"
    fi
  fi
  
  # Check if mkosi executable exists
  if [[ ! -x "$MKOSI_DIR/bin/mkosi" ]]; then
    print_error "mkosi executable not found at $MKOSI_DIR/bin/mkosi"
    exit 1
  fi
}

setup_repositories() {
  print_header "Setting up repositories for $DISTRIBUTION"
  
  # Clean up files from other distributions first
  cleanup_other_distributions
  
  # Clean up empty directories
  clean_empty_directories
  
  # Check if repository is already configured
  if [[ -f "$SANDBOX_DIR/usr/share/pacman/keyrings/system_systemd_Arch.gpg" ]] && \
      [[ -f "$SANDBOX_DIR/usr/share/pacman/keyrings/system_systemd_Arch-trusted" ]] && \
      [[ -f "$SANDBOX_DIR/etc/pacman.d/10-openSUSE.conf" ]]; then
    print_info "Arch openSUSE repository already configured, skipping..."
  else
    setup_arch_repositories
  fi
  # Check if repository is already configured
  if [[ -f "$SANDBOX_DIR/etc/yum.repos.d/system:systemd.repo" ]]; then
    print_info "Fedora openSUSE repository already configured, skipping..."
  else
    setup_fedora_repositories
  fi
  # Check if repository is already configured
  if [[ -f "$SANDBOX_DIR/etc/apt/sources.list.d/systemd-opensuse.sources" ]] && \
      [[ -f "$SANDBOX_DIR/etc/apt/keyrings/systemd-opensuse.gpg" ]]; then
    print_info "Debian openSUSE repository already configured, skipping..."
  else
    setup_debian_repositories
  fi
}

setup_arch_repositories() {
  print_info "Adding OpenSUSE repository for systemd dev (Arch)..."
  
  # Always install into the sandbox
  mkdir -p "$SANDBOX_DIR/usr/share/pacman/keyrings"
  mkdir -p "$SANDBOX_DIR/etc/pacman.d"
  
  local pacman_conf_content="[system_systemd_Arch]
Server = https://download.opensuse.org/repositories/system:/systemd/Arch/\$arch"
  
  echo "$pacman_conf_content" > "$SANDBOX_DIR/etc/pacman.d/10-openSUSE.conf"
  
  local key_url="https://download.opensuse.org/repositories/system:systemd/Arch/${ARCHITECTURE}/system_systemd_Arch.key"
  local key_file="$SANDBOX_DIR/usr/share/pacman/keyrings/system_systemd_Arch.gpg"
  
  if ! curl -o "$key_file" -fsSL "$key_url"; then
    print_error "Failed to download repository key from $key_url"
    exit 1
  fi
  
  local key fingerprint
  key=$(cat "$key_file")
  fingerprint=$(gpg --quiet --with-colons --import-options show-only --import --fingerprint <<< "${key}" | awk -F: '$1 == "fpr" { print $10 }')
  
  if [[ -z "$fingerprint" ]]; then
    print_error "Failed to extract GPG fingerprint"
    exit 1
  fi
  
  echo "$fingerprint" > "$SANDBOX_DIR/usr/share/pacman/keyrings/system_systemd_Arch-trusted"
  
  # Only if the selected distribution is arch, copy files to additional locations
  if [[ "$DISTRIBUTION" == "arch" ]]; then
    mkdir -p "$SKELETON_DIR/usr/share/pacman/keyrings"
    mkdir -p "$SKELETON_DIR/etc/pacman.d"
    echo "$pacman_conf_content" > "$SKELETON_DIR/etc/pacman.d/10-openSUSE.conf"
    cp "$key_file" "$SKELETON_DIR/usr/share/pacman/keyrings/system_systemd_Arch.gpg"
    cp "$SANDBOX_DIR/usr/share/pacman/keyrings/system_systemd_Arch-trusted" "$SKELETON_DIR/usr/share/pacman/keyrings/system_systemd_Arch-trusted"
    
    # Extra tree
    # mkdir -p "$EXTRA_DIR/usr/share/pacman/keyrings"
    # mkdir -p "$EXTRA_DIR/etc/pacman.d"
    # echo "$pacman_conf_content" > "$EXTRA_DIR/etc/pacman.d/10-openSUSE.conf"
    # cp "$key_file" "$EXTRA_DIR/usr/share/pacman/keyrings/system_systemd_Arch.gpg"
    # cp "$SANDBOX_DIR/usr/share/pacman/keyrings/system_systemd_Arch-trusted" "$EXTRA_DIR/usr/share/pacman/keyrings/system_systemd_Arch-trusted"
  fi
  
  print_success "Arch repository configured successfully"
}

setup_fedora_repositories() {
  print_info "Adding OpenSUSE repository for systemd dev (Fedora Rawhide)..."
  
  # Always install into the sandbox
  mkdir -p "$SANDBOX_DIR/etc/yum.repos.d"
  
  local repo_url="https://download.opensuse.org/repositories/system:/systemd/Fedora_Rawhide/system:systemd.repo"
  local repo_file="$SANDBOX_DIR/etc/yum.repos.d/system:systemd.repo"
  
  if ! curl -o "$repo_file" -fsSL "$repo_url"; then
    print_error "Failed to download repo file from $repo_url"
    exit 1
  fi
  
  # Only copy to additional directories if Fedora is the selected distribution
  if [[ "$DISTRIBUTION" == "fedora" ]]; then
    mkdir -p "$SKELETON_DIR/etc/yum.repos.d"
    cp "$repo_file" "$SKELETON_DIR/etc/yum.repos.d/system:systemd.repo"
    
    # Extra tree
    # mkdir -p "$EXTRA_DIR/etc/yum.repos.d"
    # cp "$repo_file" "$EXTRA_DIR/etc/yum.repos.d/system:systemd.repo"
  fi
  
  print_success "Fedora repository configured successfully"
}

setup_debian_repositories() {
  print_info "Adding OpenSUSE repository for systemd dev (Debian Testing)..."
  
  # Always install into the sandbox
  mkdir -p "$SANDBOX_DIR/etc/apt/keyrings"
  mkdir -p "$SANDBOX_DIR/etc/apt/sources.list.d"
  
  local debian_codename="Debian_Testing"
  local key_url="https://download.opensuse.org/repositories/system:systemd/${debian_codename}/Release.key"
  local key_file="$SANDBOX_DIR/etc/apt/keyrings/systemd-opensuse.gpg"
  local key_file_asc="${key_file}.asc"
  
  if ! curl -o "$key_file_asc" -fsSL "$key_url"; then
    print_error "Failed to download repository key from $key_url"
    exit 1
  fi
  
  if ! gpg --dearmor < "$key_file_asc" > "$key_file"; then
    print_error "Failed to convert GPG key to binary format"
    rm -f "$key_file_asc"
    exit 1
  fi
  
  rm -f "$key_file_asc"
  
  cat > "$SANDBOX_DIR/etc/apt/sources.list.d/systemd-opensuse.sources" <<EOF
Types: deb
URIs: http://download.opensuse.org/repositories/system:/systemd/${debian_codename}/
Suites: /
Signed-By: /etc/apt/keyrings/systemd-opensuse.gpg
EOF
  
  # Only copy to additional directories if Debian is the selected distribution
  if [[ "$DISTRIBUTION" == "debian" ]]; then
    mkdir -p "$SKELETON_DIR/etc/apt/keyrings"
    mkdir -p "$SKELETON_DIR/etc/apt/sources.list.d"
    cp "$key_file" "$SKELETON_DIR/etc/apt/keyrings/systemd-opensuse.gpg"
    cp "$SANDBOX_DIR/etc/apt/sources.list.d/systemd-opensuse.sources" "$SKELETON_DIR/etc/apt/sources.list.d/systemd-opensuse.sources"
    
    # Extra tree
    # mkdir -p "$EXTRA_DIR/etc/apt/keyrings"
    # mkdir -p "$EXTRA_DIR/etc/apt/sources.list.d"
    # cp "$key_file" "$EXTRA_DIR/etc/apt/keyrings/systemd-opensuse.gpg"
    # cp "$SANDBOX_DIR/etc/apt/sources.list.d/systemd-opensuse.sources" "$EXTRA_DIR/etc/apt/sources.list.d/systemd-opensuse.sources"
  fi
  
  print_success "Debian repository configured successfully"
}

# ═════════════════════════ Interactive Configuration ════════════════════════
configure_interactively() {
  # Set a local trap to exit if user presses Ctrl+C during interactive config.
  trap 'echo -e "\n${YELLOW}Interactive configuration aborted by user.${RESET}"; exit 1' INT

  print_header "MKOSI Build Configuration"

  # Helper function to print an option with annotation
  print_option() {
    local key="$1"
    local desc="$2"
    local current="$3"
    local default="$4"
    local annotation=""
    if [[ "$key" == "$current" ]]; then
      if [[ "$key" == "$default" ]]; then
        annotation=" (${GREEN}default, selected${RESET})"
      else
        annotation=" (${GREEN}selected${RESET})"
      fi
    elif [[ "$key" == "$default" ]]; then
      annotation=" (${YELLOW}default${RESET})"
    fi
    echo -e "  • ${BOLD}$key${RESET} - $desc$annotation"
  }

  # ── Architecture configuration ──
  echo -e "\n${MAGENTA}${BOLD}Architecture Selection${RESET}"
  echo -e "Available architectures:"
  for entry in "${VALID_ARCHITECTURES[@]}"; do
    key="${entry%%:*}"
    desc="${entry#*:}"
    print_option "$key" "$desc" "$ARCHITECTURE" "$DEFAULT_ARCHITECTURE"
  done
  read -p "Enter architecture [$ARCHITECTURE]: " input_arch
  if [[ -n "$input_arch" ]]; then
    if validate_architecture "$input_arch"; then
      ARCHITECTURE="$input_arch"
    else
      print_warning "Using default architecture: $ARCHITECTURE"
    fi
  fi

  # ── Distribution configuration ──
  echo -e "\n${MAGENTA}${BOLD}Distribution Selection${RESET}"
  echo -e "Available distributions:"
  for entry in "${VALID_DISTRIBUTIONS[@]}"; do
    key="${entry%%:*}"
    desc="${entry#*:}"
    print_option "$key" "$desc" "$DISTRIBUTION" "$DEFAULT_DISTRIBUTION"
  done
  read -p "Enter distribution [$DISTRIBUTION]: " input_dist
  if [[ -n "$input_dist" ]]; then
    if validate_distribution "$input_dist"; then
      DISTRIBUTION="$input_dist"
    else
      print_warning "Using default distribution: $DISTRIBUTION"
    fi
  fi

  # ── Profile configuration ──
  if [[ -z "$PROFILE" ]]; then
    EMPTY_PROFILE=true
  fi
  
  echo -e "\n${MAGENTA}${BOLD}Profile Selection (optional)${RESET}"
  echo -e "Available profiles:"
  # First, show the [None] option. Here the default is when PROFILE is empty.
  FORMATTED_PROFILE=$PROFILE${EMPTY_PROFILE:+None}

  # First, show the [None] option. Here the default is when PROFILE is empty.
  if [[ "$EMPTY_PROFILE" == true ]]; then
    echo -e "  • ${BOLD}[None]${RESET} - No profile (${GREEN}default, selected${RESET})"
  else
    echo -e "  • ${BOLD}[None]${RESET} - No profile (${YELLOW}default${RESET})"
  fi
  for entry in "${VALID_PROFILES[@]}"; do
    key="${entry%%:*}"
    desc="${entry#*:}"
    print_option "$key" "$desc" "$PROFILE" ""  # No default key for profiles; default is [None]
  done

  read -p "Enter profile [$FORMATTED_PROFILE]: " input_profile

  if [[ -n "$input_profile" ]]; then
    if validate_profile "$input_profile"; then
      PROFILE="$input_profile"
    else
      print_warning "Using default profile (none)"
      PROFILE=""
    fi
  fi

  # ── openSUSE package configuration ──
  echo -e "\n${MAGENTA}${BOLD}openSUSE-hosted packages for systemd${RESET}"
  echo -e "Sometimes ${BOLD}ParticleOS${RESET} adopts ${BOLD}systemd${RESET} features as soon as they get merged into ${BOLD}systemd${RESET} without waiting for an official release."
  echo -e "As such, to build with the current ${BOLD}systemd${RESET} source, either ${YELLOW}openSUSE-hosted packages${RESET} can be used, or ${BOLD}systemd${RESET} can be ${YELLOW}built from the current source${RESET}."
  echo -e "For more info on building ${BOLD}systemd${RESET}, please visit ${CYAN}https://github.com/systemd/particleos${RESET}\n"
   
  read -p "Enable openSUSE-hosted repositories for systemd packages? [Y/n]: " answer_opensuse
  if [[ -z "$answer_opensuse" || "$answer_opensuse" =~ ^[Yy] ]]; then
      USE_OPENSUSE=true
  else
      USE_OPENSUSE=false
  fi
  
  # ── Root password configuration ──
  echo -e "\n${MAGENTA}${BOLD}Root Password Configuration (optional)${RESET}"
  echo -e "Press Enter to skip setting a root password, or type one below:"
  read -s -p "Root password: " ROOT_PASSWORD
  echo

  # ── Cleaning configuration ──
  echo -e "\n${MAGENTA}${BOLD}Cleaning Option for mkosi Build${RESET}"
  echo -e "Select a cleaning option to append to the mkosi command:"
  echo -e "  1) Clean image cache only (-f) ${YELLOW}[default]${RESET}"
  echo -e "  2) Clean image cache & all packages (-ff)"
  echo -e "  3) Full clean (-ff clean), ${BOLD}will require a fresh run of the script to proceed with the build${RESET}"
  echo -e "  4) No cleaning option"
  read -p "Enter your choice [1-4]: " cleaning_choice
  case "$cleaning_choice" in
    2) CLEAN_MKOSI="-ff" ;;
    3) CLEAN_MKOSI="-ff clean" ;;
    4) CLEAN_MKOSI="" ;;
    *|1) CLEAN_MKOSI="-f" ;;
  esac
}

print_config_summary() {
  echo -e "  • ${BOLD}Architecture:${RESET}  $ARCHITECTURE"
  echo -e "  • ${BOLD}Distribution:${RESET}  $DISTRIBUTION"
  echo -e "  • ${BOLD}Profile:${RESET}       $(if [[ -n "$PROFILE" ]]; then echo "$PROFILE"; else echo "[None]"; fi)"
  echo -e "  • ${BOLD}Root Password:${RESET} $(if [[ -n "$ROOT_PASSWORD" ]]; then echo "[Set]"; else echo "[Not Set]"; fi)"
  echo -e "  • ${BOLD}openSUSE Packages:${RESET}    $(if [[ "$USE_OPENSUSE" == true ]]; then echo "Enabled"; else echo "Disabled"; fi)"
  echo -e "  • ${BOLD}Debug Mode:${RESET}    $(if $DEBUG_MODE; then echo "Enabled"; else echo "Disabled"; fi)"
  echo -e "  • ${BOLD}Cleanup Options:${RESET}    $(if [[ -n "$CLEAN_MKOSI" ]]; then echo "$CLEAN_MKOSI"; else echo "[None]"; fi)"
}

# ═════════════════════════════ Root Password Setup ═══════════════════════════
setup_root_password() {
  if [[ -n "$ROOT_PASSWORD" ]]; then
    print_info "Configuring root password..."
    echo "$ROOT_PASSWORD" > mkosi.rootpw
    if ! chmod 600 mkosi.rootpw; then
      print_error "Failed to set secure permissions on root password file"
      exit 1
    fi
    print_success "Root password configured"
  elif [[ -f "mkosi.rootpw" ]]; then
    if ! rm -f mkosi.rootpw; then
      print_error "Failed to remove existing root password file"
      exit 1
    fi
    print_info "Removed existing root password configuration"
  fi
}

# ════════════════════════════ Parse Arguments ═══════════════════════════════
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --arch=*)
        ARCHITECTURE="${1#*=}"
        if ! validate_architecture "$ARCHITECTURE"; then
          exit 1
        fi
        ;;
      --arch)
        shift
        if [[ -z "$1" ]]; then
          print_error "Missing argument for --arch. Usage: --arch=<architecture>"
          exit 1
        fi
        ARCHITECTURE="$1"
        if ! validate_architecture "$ARCHITECTURE"; then exit 1; fi
        ;;
      --dist=*)
        DISTRIBUTION="${1#*=}"
        if ! validate_distribution "$DISTRIBUTION"; then
          exit 1
        fi
        ;;
      --dist)
        shift
        if [[ -z "$1" ]]; then
          print_error "Missing argument for --dist. Usage: --dist=<distribution>"
          exit 1
        fi
        DISTRIBUTION="$1"
        if ! validate_distribution "$DISTRIBUTION"; then exit 1; fi
        ;;
      -d)
        shift
        if [[ -z "$1" ]]; then
          print_error "Missing argument for -d option. Usage: -d <distribution>"
          exit 1
        fi
        DISTRIBUTION="$1"
        if ! validate_distribution "$DISTRIBUTION"; then exit 1; fi
        ;;
      --profile=*)
        PROFILE="${1#*=}"
        if ! validate_profile "$PROFILE"; then exit 1; fi
        ;;
      --profile)
        shift
        if [[ -z "$1" ]]; then
          print_error "Missing argument for --profile. Usage: --profile=<profile>"
          exit 1
        fi
        PROFILE="$1"
        if ! validate_profile "$PROFILE"; then exit 1; fi
        ;;
      --root-password=*)
        ROOT_PASSWORD="${1#*=}"
        ;;
      --root-password)
        shift
        if [[ -z "$1" ]]; then
          print_error "Missing argument for --root-password. Usage: --root-password=<password>"
          exit 1
        fi
        ROOT_PASSWORD="$1"
        ;;
      --opensuse)
        USE_OPENSUSE=true
        ;;
      --debug)
        DEBUG_MODE=true
        ;;
      --interactive)
        INTERACTIVE=true
        ;;
      -f)
        if [[ $# -gt 1 && "$2" == "clean" ]]; then
            CLEAN_MKOSI="-f clean"
            shift
        else
            CLEAN_MKOSI="-f"
        fi
        ;;
      -ff)
        if [[ $# -gt 1 && "$2" == "clean" ]]; then
            CLEAN_MKOSI="-ff clean"
            shift
        else
            CLEAN_MKOSI="-ff"
        fi
        ;;
      -w)
        CLEAN_BUILD=true
        ;;
      -confirm)
        FORCE_CONFIRM=true
        ;;
      -c)
        FORCE_CONFIRM=true
        ;;
      --help|-h)
        cat <<EOF
Usage: $0 [options]

Options:
  --arch=ARCH                Set architecture (x86_64, aarch64)
  --dist=DIST, -d DIST       Set distribution (fedora, arch, debian)
  --profile=PROFILE          Set profile (desktop,gnome; desktop,kde; desktop)
  --root-password=PASS       Set root password
  --opensuse                 Force use of openSUSE packages for systemd, otherwise detects if ExtraSearchPaths are configured
  --confirm, -c              Force a confirmation prompt before proceeeding with the build
  --debug                    Show debug output during the mkosi build
  --interactive              Show interactive configuration
  -f                         Clear cached images from the build, can use alongside 'clean'
  -ff                        Clear cached images and packages from mkosi, can use alongside 'clean'
  -w                         Clear the mkosi build directory
  --help, -h                 Show this help message
EOF
        exit 0
        ;;
      -*)
        print_error "Unknown option: $1"
        echo "Run '$0 --help' for usage information"
        exit 1
        ;;
      *)
        print_error "Unexpected argument: $1"
        echo "Run '$0 --help' for usage information"
        exit 1
        ;;
    esac
    shift
  done
}

# ════════════════════════════ Run Mkosi ═════════════════════════════════════
run_mkosi() {
  print_header "Building Image with MKOSI"
  
  # Check if keys already exist
  if [[ -f "mkosi.key" && -f "mkosi.crt" ]]; then
    print_info "Secure boot keys already exist, skipping key generation"
  else
    print_info "Generating secure boot keys..."
    if ! "$MKOSI_DIR/bin/mkosi" genkey; then
      print_error "Failed to generate secure boot keys"
      exit 1
    fi
    print_success "Keys generated successfully"
  fi
  
  # Set up root password if specified
  setup_root_password
  
  # Build the command
  cmd="$MKOSI_DIR/bin/mkosi -d $DISTRIBUTION${PROFILE:+ --profile $PROFILE}${CLEAN_MKOSI:+ $CLEAN_MKOSI}${CLEAN_BUILD:+ -w}"
  
  if $DEBUG_MODE; then
    cmd+=" --debug"
  fi
  
  print_info "Building image with command: $cmd"
  echo
  if ! eval "$cmd"; then
    print_error "mkosi build failed"
    exit 1
  fi
}

# ═════════════════════════════ Main Execution ═══════════════════════════════
main() {
  # Register a trap to do cleanup on exit
  trap cleanup EXIT
  
  # Check dependencies
  check_dependencies
  
  ARGS_COUNT=$#
  # Parse command line arguments
  parse_args "$@"
  
  # If no args were provided, enable interactive configuration.
  if [[ $ARGS_COUNT -eq 0 ]]; then
    INTERACTIVE=true
  fi
  
  # In non-interactive mode, if USE_OPENSUSE is not already set via flag, use detection.
  if ! $INTERACTIVE; then
    if [[ -z "$USE_OPENSUSE" ]]; then
      if [[ $(detect_default_opensuse) == "yes" ]]; then
        USE_OPENSUSE=true
      else
        USE_OPENSUSE=false
      fi
    fi
  fi
  
  # Wrap interactive configuration in a confirmation loop if enabled.
  if $INTERACTIVE; then
    while true; do
      configure_interactively
      
      print_header "Configuration Summary"
      print_config_summary
      
      read -p "Are these settings correct? [Y/n]: " answer
      # If the answer is yes (or empty), break out of the loop.
      if [[ "$answer" =~ ^[Yy]$ || -z "$answer" ]]; then
        break
      else
        print_warning "Reconfiguring interactive options..."
      fi
    done
  elif [[ "$FORCE_CONFIRM" == true ]]; then
    print_header "Final Configuration Summary"
    print_config_summary

    read -p "Are you sure you want to proceed? [y/N]: " force_confirm_answer
    if [[ ! "$force_confirm_answer" =~ ^[Yy]$ ]]; then
      echo "Build cancelled. Exiting."
      exit 1
    fi
  else
    # Display final configuration summary before proceeding.
    print_header "Final Configuration Summary"
    print_config_summary
  fi
  
  
  
  # Setup mkosi and conditionally setup repositories based on openSUSE option.
  setup_mkosi
  if [[ "$USE_OPENSUSE" == true ]]; then
      setup_repositories
  else
      print_info "openSUSE packages not enabled, skipping repository configuration."
      cleanup_opensuse_repos
  fi
  run_mkosi
  
  print_success "Build completed successfully!"
  
  # Cleanup happens automatically through the trap
}

# Execute main function
main "$@"
