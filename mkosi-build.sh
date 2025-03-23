#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# Mkosi Build Script
#
# This script provides both interactive and CLI interfaces to configure and 
# build Linux images through mkosi. It manages keys, profiles, and 
# distribution settings to create a customized system image.
#
# Required Dependencies:
# - bash 4.0+
# - git
# - python 3.0+
# - grep, sed
# - mktemp
# ══════════════════════════════════════════════════════════════════════════════
# Check for bash
if [ -z "$BASH_VERSION" ]; then
  echo "This script requires bash. Please run with: bash $0" >&2
  exit 1
fi

# -e: Exit immediately if a command exits with a non-zero status
set -e

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
# Repository settings
readonly MKOSI_DIR="mkosi"

# Default settings
readonly DEFAULT_ARCHITECTURE="$(uname -m)"
readonly DEFAULT_DISTRIBUTION="fedora"
readonly DEFAULT_PROFILE=""  # No profile by default

# Architecture aliases for user convenience
declare -A ARCH_ALIASES
ARCH_ALIASES=(
  ["arm64"]="aarch64"
  ["arm32"]="arm"
  ["x86-64"]="x86_64"
  ["x86"]="i386"
  ["amd64"]="x86_64"
  ["ppc64el"]="ppc64-le"
  ["armhf"]="arm"
)

# Available architectures with descriptions - order matters for UI
readonly VALID_ARCHITECTURES=(
  "x86_64:64-bit Intel/AMD architecture"
  "aarch64:64-bit ARM architecture"
  "ppc64-le:64-bit PowerPC little-endian"
  "s390x:64-bit IBM System z"
  "arm:32-bit ARM architecture"
  "i386:32-bit Intel/AMD architecture"
  "mips64el:64-bit MIPS little-endian"
  "mipsel:32-bit MIPS little-endian"
)

# Common architectures to show in the UI - order matters
readonly COMMON_ARCHITECTURES=(
  "x86_64:64-bit Intel/AMD architecture"
  "aarch64:64-bit ARM architecture"
)

# Available distributions with descriptions - order matters
readonly VALID_DISTRIBUTIONS=(
  "fedora:Fedora Linux"
  "arch:Arch Linux"
  "debian:Debian Linux"
)

# Individual profiles with descriptions - order matters
readonly VALID_PROFILES=(
  "desktop:Desktop base profile"
  "gnome:GNOME Desktop environment"
  "kde:KDE Desktop environment"
  "obs:OBS packages for systemd"
)

# Profiles that shouldn't be used alone
declare -A STANDALONE_PROFILES
STANDALONE_PROFILES=(
  ["gnome"]="desktop:GNOME Desktop environment (recommended with desktop)"
  ["kde"]="desktop:KDE Desktop environment (recommended with desktop)"
)

# Recommended profile combinations - order matters
readonly RECOMMENDED_COMBINATIONS=(
  "desktop,gnome:GNOME Desktop (recommended)"
  "desktop,kde:KDE Desktop (recommended)"
)

# Runtime configuration (initialized with defaults)
ARCHITECTURE="$DEFAULT_ARCHITECTURE"
DISTRIBUTION="$DEFAULT_DISTRIBUTION"
PROFILE="$DEFAULT_PROFILE"
ROOT_PASSWORD=""
DEBUG_MODE=false
INTERACTIVE=false  # Interactive mode is off if args are provided
CLEAN_MKOSI="-f"
FORCE_CONFIRM=false
CLEAN_BUILD=false
OBS_REPOS=true
FULLSCREEN_MODE=false

# ═════════════════════════════ UI Helper Functions ═════════════════════════════
reset_colors() { printf "\033[0m\033[49m"; }

# Central message output function for consistent formatting
print_message() {
  local type="$1"
  local message="$2"
  local symbol=""
  local color="$RESET"
  
  if $FULLSCREEN_MODE; then
    # Get terminal size using stty
    local size
    size=$(stty size 2>/dev/null || echo "24 80")
    local height=${size%% *}
    local width=${size##* }
    width=$((width - 1))  # Prevent wrapping
    
    case "$type" in
      "clear")
        printf "\033[2J\033[H"  # Clear and home
        return
        ;;
      "header")
        printf "\033[1;34m%s\033[0m\n" "$message"  # Blue, bold text
        printf "\033[1;34m%s\033[0m\n" "$(printf '═%.0s' $(seq 1 ${#message}))"
        return
        ;;
      "info")     symbol="→"; color="$CYAN";;
      "success")  symbol="✓"; color="$GREEN";;
      "warning")  symbol="!"; color="$YELLOW";;
      "error")    symbol="✗"; color="$RED"; >&2;;
    esac
    
    printf "%b %s\n" "${color}${symbol}${RESET}" "$message"
    return
  fi
  
  # Standard terminal output
  case "$type" in
    "header")
      echo -e "\n${BLUE}${BOLD}${message}${RESET}"
      echo -e "${BLUE}${BOLD}$(printf '═%.0s' $(seq 1 ${#message}))${RESET}"
      ;;
    "info")
      echo -e "${CYAN}${BOLD}→${RESET} ${message}"
      ;;
    "success")
      echo -e "${GREEN}${BOLD}✓${RESET} ${message}"
      ;;
    "warning") 
      echo -e "${YELLOW}${BOLD}!${RESET} ${message}"
      ;;
    "error")
      echo -e "${RED}${BOLD}✗${RESET} ${message}" >&2
      ;;
  esac
}

# Display formatted header message
print_header() {
  print_message "header" "$1"
}

# Display information message
print_info() {
  print_message "info" "$1"
}

# Display success message
print_success() {
  print_message "success" "$1"
}

# Display warning message
print_warning() {
  print_message "warning" "$1"
}

# Display error message to stderr
print_error() {
  print_message "error" "$1"
}

# Check if a command exists in PATH
# Used throughout the script to check for required tools
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Initialize tracked files array
declare -a TRACKED_FILES=()

# Add a file to tracked files for cleanup
track_file() {
  local file="$1"
  TRACKED_FILES+=("$file")
}

# Create and track a temporary file
create_temp_file() {
  local prefix="${1:-mkosi-tmp}"
  local temp_file
  
  temp_file=$(mktemp "${SCRIPT_DIR}/${prefix}.XXXXXX") || {
    print_error "Failed to create temporary file"
    return 1
  }
  
  # Set secure permissions
  chmod 600 "$temp_file"
  
  # Add to tracked files
  track_file "$temp_file"
  
  # Return the filename to caller
  echo "$temp_file"
}

# Compare version strings
# Returns 0 if ver1 < ver2, 1 otherwise
version_compare() {
  local ver1="$1" ver2="$2"
  local IFS=.
  local i ver1_arr=($ver1) ver2_arr=($ver2)
  
  for ((i=0; i<${#ver1_arr[@]} || i<${#ver2_arr[@]}; i++)); do
    local v1=${ver1_arr[i]:-0} v2=${ver2_arr[i]:-0}
    if ((10#$v1 > 10#$v2)); then
      return 1  # ver1 > ver2
    elif ((10#$v1 < 10#$v2)); then
      return 0  # ver1 < ver2
    fi
  done
  return 1  # Equal or ver1 > ver2 (remaining segments are 0)
}

# Save current configuration to file
save_configuration() {
  local config_file="${1:-${SCRIPT_DIR}/particleos-config.conf}"
  
  {
    echo "# ParticleOS build configuration saved on $(date)"
    echo "ARCHITECTURE=\"$ARCHITECTURE\""
    echo "DISTRIBUTION=\"$DISTRIBUTION\""
    echo "PROFILE=\"$PROFILE\""
    echo "DEBUG_MODE=$DEBUG_MODE"
    echo "CLEAN_MKOSI=\"$CLEAN_MKOSI\""
    echo "OBS_REPOS=$OBS_REPOS"
  } > "$config_file"
  
  chmod 600 "$config_file"
  print_info "Configuration saved to: $config_file"
}

# Load configuration from file
load_configuration() {
  local config_file="${1:-${SCRIPT_DIR}/particleos-config.conf}"
  
  if [[ ! -f "$config_file" ]]; then
    print_error "Configuration file not found: $config_file"
    return 1
  fi
  
  print_info "Loading configuration from: $config_file"
  source "$config_file"
  
  # Validate loaded configuration
  if ! validate_architecture "$ARCHITECTURE"; then
    print_warning "Invalid architecture in config file, using default: $DEFAULT_ARCHITECTURE"
    ARCHITECTURE="$DEFAULT_ARCHITECTURE"
  fi
  
  if ! validate_distribution "$DISTRIBUTION"; then
    print_warning "Invalid distribution in config file, using default: $DEFAULT_DISTRIBUTION"
    DISTRIBUTION="$DEFAULT_DISTRIBUTION"
  fi
  
  if ! validate_profile "$PROFILE"; then
    print_warning "Invalid profile in config file, using default: $DEFAULT_PROFILE"
    PROFILE="$DEFAULT_PROFILE"
  fi
  
  return 0
}

# Auto-detect if we should add obs profile
auto_detect_obs_profile() {
  # Only auto-detect if obs is not explicitly mentioned in the command line
  if [[ ",${PROFILE:-}," != *",obs,"* && "${PROFILE:-}" != "obs" ]]; then
    if [[ $(detect_default_obs) == "yes" ]]; then
      # Detection indicates we should use OBS packages
      OBS_REPOS=true
      if [[ -z "${PROFILE:-}" ]]; then
        PROFILE="obs"
      else
        PROFILE="${PROFILE},obs"
      fi
      print_info "Auto-detected: Adding obs profile based on system configuration"
    else
      OBS_REPOS=false
      print_info "Auto-detected: Not using obs profile based on system configuration"
    fi
  fi
}


# ═══════════════════════════ Error Handling ═════════════════════════════════
# Get script directory for consistent file access regardless of where script is called from
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


# Execute command with error handling
# Takes a command and optional error message, timeout, and fallback function
safe_exec() {
  local cmd="$1"
  local error_msg="${2:-Command failed: $cmd}"
  local timeout="${3:-0}"
  local fallback_func="${4:-}"
  
  # Add timeout if specified
  if [[ $timeout -gt 0 ]]; then
    if command_exists timeout; then
      cmd="timeout $timeout $cmd"
    else
      print_warning "timeout command not found, executing without timeout"
    fi
  fi
  
  # Execute command with error capture
  local output
  local exit_code
  
  if ! output=$(eval "$cmd" 2>&1); then
    exit_code=$?
    print_error "$error_msg"
    print_error "Command: $cmd"
    print_error "Exit code: $exit_code"
    print_error "Output: $output"
    
    # Call fallback function if provided
    if [[ -n "$fallback_func" && $(type -t "$fallback_func") == function ]]; then
      print_info "Attempting fallback procedure..."
      if $fallback_func; then
        print_success "Fallback succeeded"
        return 0
      else
        print_error "Fallback failed"
      fi
    fi
    
    return $exit_code
  fi
  
  return 0
}

# Error handler to provide more detailed information on failures
error_handler() {
  local line=$1
  local cmd=$2
  local code=${3:-1}
  
  echo -e "\n${RED}${BOLD}ERROR: Command '$cmd' failed with exit code $code at line $line${RESET}" >&2
  
  # Provide additional context if available
  if [[ -n "${FUNCNAME[1]}" ]]; then
    echo -e "${RED}Function: ${FUNCNAME[1]}${RESET}" >&2
  fi
  
  # Suggest recovery actions based on error pattern
  case "$cmd" in
    *git*)
      echo -e "${YELLOW}This might be a network issue or repository problem.${RESET}" >&2
      echo -e "${YELLOW}Try checking your network connection or repository URL.${RESET}" >&2
      ;;
    *mkosi*)
      echo -e "${YELLOW}This might be an issue with mkosi configuration or dependencies.${RESET}" >&2
      echo -e "${YELLOW}Check that all required dependencies are installed.${RESET}" >&2
      ;;
    *mount*)
      echo -e "${YELLOW}This might be a filesystem or permission issue.${RESET}" >&2
      echo -e "${YELLOW}Make sure you have appropriate permissions.${RESET}" >&2
      ;;
  esac
  
  exit $code
}

# Clean up function for temp files
cleanup() {
  print_info "Cleaning up temporary files..."
  
  local cleanup_failed=0
  
  # Remove temporary root password file if we created it
  if [[ -f "${SCRIPT_DIR}/mkosi.rootpw" ]] && [[ -z "${ROOT_PASSWORD:-}" ]]; then
    if ! rm -f "${SCRIPT_DIR}/mkosi.rootpw"; then
      print_warning "Failed to remove temporary root password file"
      cleanup_failed=1
    fi
  fi
  
  # Clean up tracked temporary files
  for file in "${TRACKED_FILES[@]}"; do
    if [[ -f "$file" ]]; then
      if ! rm -f "$file"; then
        print_warning "Failed to remove temporary file: $file"
        cleanup_failed=1
      fi
    fi
  done
  
  if [[ $cleanup_failed -eq 0 ]]; then
    print_success "Cleanup completed successfully"
  else
    print_warning "Cleanup completed with some errors"
  fi
}

interrupt_handler() {
  echo -e "\n${YELLOW}${BOLD}Script interrupted by user.${RESET}"
  echo -e "${YELLOW}Cleaning up before exit...${RESET}"
  cleanup
  exit 130
}

register_handlers() {
  trap 'cleanup' EXIT
  trap 'error_handler ${LINENO} "$BASH_COMMAND" $?' ERR
  trap 'interrupt_handler' INT TERM
}

# ════════════════════════════ Validation Functions ══════════════════════════

# Generic validation function for options against a list
# Returns 0 if valid, 1 if invalid
validate_option() {
  local option_type="$1"   # Type of option (architecture, distribution, profile)
  local value="$2"         # Value to validate
  local array_name="$3"    # Array containing valid values
  local allow_empty="${4:-false}"  # Whether empty value is valid
  local allow_unknown="${5:-false}"  # Whether unknown values should be accepted with warning
  
  # Empty check if applicable
  if [[ -z "$value" && "$allow_empty" == "true" ]]; then
    return 0
  fi
  
  # Use indirect reference to access the array
  declare -n options="$array_name"
  
  # Check against valid values
  for entry in "${options[@]}"; do
    local key="${entry%%:*}"
    if [[ "$value" == "$key" ]]; then
      return 0  # Valid
    fi
  done
  
  # Special case handling
  if [[ "$option_type" == "architecture" && "$allow_unknown" == "true" ]]; then
    print_warning "Architecture '$value' is not in the common list but will be accepted"
    return 0
  fi
  
  # Value not found in valid options
  print_error "Invalid $option_type: $value"
  echo -e "  ${YELLOW}Valid ${option_type}s:${RESET}"
  for entry in "${options[@]}"; do
    local key="${entry%%:*}"
    local desc="${entry#*:}"
    echo -e "    • ${BOLD}$key${RESET} - $desc"
  done
  
  if [[ "$option_type" == "architecture" ]]; then
    echo -e "  ${YELLOW}Additional architectures are supported but not listed.${RESET}"
  fi
  
  return 1
}

# Convert an architecture alias to its canonical form
normalize_architecture() {
  local input="$1"
  
  # Check if the input is an alias
  if [[ -n "${ARCH_ALIASES[$input]}" ]]; then
    local canonical="${ARCH_ALIASES[$input]}"
    if [[ "$DEBUG_MODE" == true ]]; then
      print_info "Converting architecture alias '$input' to canonical form '$canonical'"
    fi
    echo "$canonical"
  else
    # Return the original if not an alias
    echo "$input"
  fi
}

# Validate architecture against allowed values
validate_architecture() {
  local input="$1"
  local normalized_input
  local quiet="${2:-false}"
  
  # Normalize the input architecture (convert alias to canonical form)
  normalized_input=$(normalize_architecture "$input")
  
  # If the input was an alias, inform the user
  if [[ "$normalized_input" != "$input" && "$quiet" != "true" ]]; then
    print_info "Converting architecture alias '$input' to '$normalized_input'"
    # Update the original variable if we're validating the global ARCHITECTURE variable
    if [[ "$input" == "$ARCHITECTURE" ]]; then
      ARCHITECTURE="$normalized_input"
    fi
  fi
  
  # First check if it's in our common architectures
  if validate_option "architecture" "$normalized_input" "VALID_ARCHITECTURES" "false" "no-output"; then
    return 0
  fi
  
  # If not in our common list, accept it with a warning
  # This is because we support more architectures than we list
  if [[ "$quiet" != "true" ]]; then
    print_warning "Architecture '$normalized_input' is not in the common list but will be accepted"
  fi
  return 0
}

# Validate distribution against allowed values
validate_distribution() {
  local dist="$1"
  local quiet="${2:-false}"
  
  if validate_option "distribution" "$dist" "VALID_DISTRIBUTIONS" "false" "no-output"; then
    return 0
  fi
  
  if [[ "$quiet" != "true" ]]; then
    print_error "Invalid distribution: $dist"
    echo -e "  ${YELLOW}Valid distributions:${RESET}"
    for entry in "${VALID_DISTRIBUTIONS[@]}"; do
      local key="${entry%%:*}"
      local desc="${entry#*:}"
      echo -e "    • ${BOLD}$key${RESET} - $desc"
    done
  fi
  
  return 1
}

# Validate profile with relevant error messages
validate_profile() {
  local profile_list="$1"
  local quiet="${2:-false}"
  
  # Empty profile is valid
  if [[ -z "$profile_list" ]]; then
    return 0
  fi
  
  # Split the profile string into an array using commas
  IFS=',' read -ra requested_profiles <<< "$profile_list"
  
  # Check each individual profile for validity
  for profile in "${requested_profiles[@]}"; do
    local found=false
    
    # Check in VALID_PROFILES
    for entry in "${VALID_PROFILES[@]}"; do
      local key="${entry%%:*}"
      if [[ "$profile" == "$key" ]]; then
        found=true
        break
      fi
    done
    
    if [[ "$found" == "false" ]]; then
      if [[ "$quiet" != "true" ]]; then
        print_error "Invalid profile: $profile"
        echo -e "  ${YELLOW}Valid profiles:${RESET}"
        for entry in "${VALID_PROFILES[@]}"; do
          local key="${entry%%:*}"
          local desc="${entry#*:}"
          echo -e "    • ${BOLD}$key${RESET} - $desc"
        done
        
        # Handle different modes appropriately
        if [[ "$INTERACTIVE" == false ]]; then
          return 1
        fi

        # In interactive mode, ask if they want to continue with default
        read -p "Continue with default profile (none)? [Y/n]: " answer
        if [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; then
          print_warning "Using default profile (none)"
          PROFILE=""
          return 0
        else
          return 1
        fi
      else
        return 1
      fi
    fi
  done
  
  return 0
}

# ════════════════════════════ Setup Functions ═══════════════════════════════
# Check for required dependencies with version requirements
check_dependencies() {
  local missing=0
  
  # Required commands with minimum versions where applicable
  declare -A required_versions=(
    ["git"]="2.0.0"
    ["python3"]="3.0.0"
  )
  
  for cmd in "${!required_versions[@]}"; do
    if ! command_exists "$cmd"; then
      print_error "Required command not found: $cmd"
      missing=1
      continue
    fi
    
    # Check version for critical components
    local version_str
    local actual_version
    
    case "$cmd" in
      git)
        version_str=$("$cmd" --version 2>/dev/null)
        actual_version=$(echo "$version_str" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        ;;
      python3)
        version_str=$("$cmd" --version 2>/dev/null)
        actual_version=$(echo "$version_str" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        ;;
    esac
    
    if [[ -n "$actual_version" ]]; then
      # Compare versions (simplified)
      local required="${required_versions[$cmd]}"
      if ! version_compare "$required" "$actual_version"; then
        print_warning "Detected $cmd version $actual_version, but ${required_versions[$cmd]} or higher is recommended"
      fi
    fi
  done
  
  if [[ $missing -eq 1 ]]; then
    print_error "Please install the missing dependencies and try again"
    exit 1
  fi
}

# Set up mkosi repository
setup_mkosi() {
  print_header "Setting up mkosi"
  
  # Clone or update mkosi repository
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
  
  # Verify mkosi executable exists
  if [[ ! -x "$MKOSI_DIR/bin/mkosi" ]]; then
    print_error "mkosi executable not found at $MKOSI_DIR/bin/mkosi"
    exit 1
  fi
}

# Configure root password if specified
setup_root_password() {
  local password_file="${SCRIPT_DIR}/mkosi.rootpw"
  
  if [[ -n "${ROOT_PASSWORD:-}" ]]; then
    print_info "Configuring root password..."
    
    # Validate password strength if non-empty
    if [[ ${#ROOT_PASSWORD} -lt 8 ]]; then
      print_warning "Password is less than 8 characters, which is not recommended for security"
      read -p "Use this password anyway? [y/N]: " pw_confirm
      if [[ ! "$pw_confirm" =~ ^[Yy]$ ]]; then
        print_error "Password configuration aborted"
        ROOT_PASSWORD=""
        return 1
      fi
    fi
    
    # Create temp file first, then move atomically
    local temp_pw_file
    temp_pw_file=$(create_temp_file "mkosi-rootpw")
    
    echo "$ROOT_PASSWORD" > "$temp_pw_file"
    chmod 600 "$temp_pw_file"
    
    # Move atomically to final location
    if ! mv "$temp_pw_file" "$password_file"; then
      print_error "Failed to save root password file"
      rm -f "$temp_pw_file"
      return 1
    fi
    
    print_success "Root password configured securely"
  elif [[ -f "$password_file" ]]; then
    # Remove existing file if no password specified
    print_info "Removing existing root password configuration..."
    if ! rm -f "$password_file"; then
      print_error "Failed to remove existing root password file"
      return 1
    fi
    print_info "Removed existing root password configuration"
  fi
  
  return 0
}

# Check and setup secure boot keys
setup_secure_boot_keys() {
  local key_file="${SCRIPT_DIR}/mkosi.key"
  local cert_file="${SCRIPT_DIR}/mkosi.crt"
  local mkosi_bin="${MKOSI_DIR}/bin/mkosi"
  
  if [[ -f "$key_file" && -f "$cert_file" ]]; then
    # Verify key files are valid
    if [[ ! -s "$key_file" || ! -s "$cert_file" ]]; then
      print_warning "Existing secure boot key files may be empty or missing"
    elif ! grep -q "PRIVATE KEY" "$key_file" 2>/dev/null || 
         ! grep -q "CERTIFICATE" "$cert_file" 2>/dev/null; then
      print_warning "Existing secure boot key files may be corrupted"
      read -p "Regenerate keys? [Y/n]: " regen_keys
      if [[ -z "$regen_keys" || "$regen_keys" =~ ^[Yy]$ ]]; then
        print_info "Backing up existing keys with .bak extension"
        cp "$key_file" "${key_file}.bak" 2>/dev/null
        cp "$cert_file" "${cert_file}.bak" 2>/dev/null
        rm -f "$key_file" "$cert_file"
      fi
    else
      print_info "Secure boot keys already exist and appear valid, skipping key generation"
      return 0
    fi
  fi
  
  # Generate keys if they don't exist or were removed due to corruption
  if [[ ! -f "$key_file" || ! -f "$cert_file" ]]; then
    print_info "Generating secure boot keys..."
    if ! safe_exec "$mkosi_bin genkey" "Failed to generate secure boot keys" "300"; then
      print_error "Key generation failed - check if you have enough entropy"
      return 1
    fi
    print_success "Keys generated successfully"
    
    # Verify the newly generated keys
    if [[ ! -f "$key_file" || ! -f "$cert_file" ]]; then
      print_error "Key generation appeared to succeed but key files not found"
      return 1
    fi
  fi
  
  return 0
}

# ═════════════════════════ Interactive Configuration ════════════════════════
# Display an option with optional annotation for current/default
print_option() {
  local key="$1"
  local desc="$2"
  local current="$3"
  local default="$4"
  local annotation=""
  
  if [[ "$key" == "$current" ]]; then
    if [[ "$key" == "$default" ]]; then
      annotation=" (${GREEN}selected, default${RESET})"
    else
      annotation=" (${GREEN}selected${RESET})"
    fi
  elif [[ "$key" == "$default" ]]; then
    annotation=" (${YELLOW}default${RESET})"
  fi
  
  echo -e "  • ${BOLD}$key${RESET} - $desc$annotation"
}

# Interactive configuration module
# Display a configuration section header
display_config_header() {
  local title="$1"
  local description="${2:-}"
  
  echo -e "\n${MAGENTA}${BOLD}${title}${RESET}"
  if [[ -n "$description" ]]; then
    echo -e "$description"
  fi
}

# Generic function to display options with annotations
# Shows current selection, defaults and handles formatting
display_options_generic() {
  local array_name="$1"
  local current_value="$2"
  local default_value="${3:-}"
  local additional_text="${4:-}"
  
  # Display additional text if provided
  if [[ -n "$additional_text" ]]; then
    echo -e "$additional_text"
  fi
  
  # Use indirect reference to access the array
  declare -n options="$array_name"
  
  # Display each option
  for entry in "${options[@]}"; do
    local key="${entry%%:*}"
    local desc="${entry#*:}"
    print_option "$key" "$desc" "$current_value" "$default_value"
  done
}

# Generic function to get user input with validation
# Returns the validated input or the original value if unchanged
get_validated_input() {
  local prompt="$1"
  local current_value="$2"
  local validator="$3"
  local validation_args="${4:-}"
  local input
  
  read -p "$prompt [$current_value]: " input
  
  # Return current value if no input
  if [[ -z "$input" ]]; then
    echo "$current_value"
    return 0
  fi
  
  # Validate input if validator function provided
  if [[ -n "$validator" ]]; then
    if $validator "$input" $validation_args; then
      echo "$input"
      return 0
    else
      print_warning "Invalid input. Using current value: $current_value"
      echo "$current_value"
      return 1
    fi
  fi
  
  # No validator, return input as is
  echo "$input"
  return 0
}

# Boolean option handler - specialized for yes/no questions
# Accepts different formats for true/false responses
handle_boolean_option() {
  local prompt="$1"
  local current_value="$2"  # Should be true/false
  local default_char
  
  # Format the default in prompt
  if $current_value; then
    default_char="Y/n"
  else
    default_char="y/N"
  fi
  
  read -p "$prompt [$default_char]: " answer
  
  # Process answer
  if [[ -z "$answer" ]]; then
    # Use default
    echo "$current_value"
  elif [[ "$answer" =~ ^[Yy]$ ]]; then
    echo true
  elif [[ "$answer" =~ ^[Nn]$ ]]; then
    echo false
  else
    # Invalid input, use default
    print_warning "Invalid input. Using current value: $current_value"
    echo "$current_value"
  fi
}

# Handle architecture selection
handle_architecture_selection() {
  display_config_header "Architecture Selection" 
  display_options_generic "COMMON_ARCHITECTURES" "$ARCHITECTURE" "$DEFAULT_ARCHITECTURE"
  echo -e "\n${YELLOW}Note: Additional architectures are supported. Type the exact name if not listed above.${RESET}"
  
  local new_arch
  new_arch=$(get_validated_input "Enter architecture" "$ARCHITECTURE" "validate_architecture")
  
  # Only assign if there was a change and validation passed
  if [[ "$new_arch" != "$ARCHITECTURE" ]]; then
    ARCHITECTURE="$new_arch"
    print_info "Architecture set to: $ARCHITECTURE"
  else
    print_info "Using architecture: $ARCHITECTURE"
  fi
}

# Handle distribution selection
handle_distribution_selection() {
  display_config_header "Distribution Selection"
  display_options_generic "VALID_DISTRIBUTIONS" "$DISTRIBUTION" "$DEFAULT_DISTRIBUTION"
  
  local new_dist
  new_dist=$(get_validated_input "Enter distribution" "$DISTRIBUTION" "validate_distribution")
  
  # Only assign if there was a change and validation passed
  if [[ "$new_dist" != "$DISTRIBUTION" ]]; then
    DISTRIBUTION="$new_dist"
    print_info "$DISTRIBUTION distribution set."
  else
    print_info "Using distribution: $DISTRIBUTION"
  fi
}

# Handle profile selection
handle_profile_selection() {
  display_config_header "Profile Selection (optional)" "You can select individual profiles or combinations separated by commas."
  
  # Common code to display available profiles
  display_profile_options() {
    local current_profile="$1"
    
    # Show the [None] option
    if [[ -z "$current_profile" ]]; then
      echo -e "  • ${BOLD}[None]${RESET} - No profile (${GREEN}selected${RESET})"
    else
      echo -e "  • ${BOLD}[None]${RESET} - No profile"
    fi
    
    # Show individual profiles
    echo -e "Available profiles:"
    for entry in "${VALID_PROFILES[@]}"; do
      local key="${entry%%:*}"
      local desc="${entry#*:}"
      
      # Skip the 'obs' profile, this is configured separately
      if [[ "$key" == "obs" ]]; then
        continue
      fi
      
      # Check if this profile is part of the current selection
      if [[ "$current_profile" == "$key" || ",${current_profile}," == *",${key},"* ]]; then
        echo -e "  • ${BOLD}$key${RESET} - $desc (${GREEN}selected${RESET})"
      else
        echo -e "  • ${BOLD}$key${RESET} - $desc"
      fi
    done
    
    # Show recommended combinations
    echo -e "\nRecommended combinations:"
    for entry in "${RECOMMENDED_COMBINATIONS[@]}"; do
      local key="${entry%%:*}"
      local desc="${entry#*:}"
      
      if [[ "$current_profile" == "$key" ]]; then
        echo -e "  • ${BOLD}$key${RESET} - $desc (${GREEN}selected${RESET})"
      else
        echo -e "  • ${BOLD}$key${RESET} - $desc"
      fi
    done
  }
  
  # Display available profile options
  display_profile_options "$PROFILE"
  
  # Get user input for profile
  read -p "Enter profile [$PROFILE]: " input_profile
  
  # Process input_profile
  if [[ -n "$input_profile" ]]; then
    # Check if the selected profile should typically be combined with another
    if [[ -n "${STANDALONE_PROFILES[$input_profile]}" ]]; then
      # Get recommended base profile and description
      IFS=':' read -r recommended_base recommended_desc <<< "${STANDALONE_PROFILES[$input_profile]}"
      
      local confirm
      read -p "You've selected just '$input_profile' without '$recommended_base'. Is this intentional? [Y/n]: " confirm
      if [[ -z "$confirm" || "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Using '$input_profile' profile without '$recommended_base'"
      else
        local use_combination
        read -p "Would you like to use '$recommended_base,$input_profile' instead? [Y/n]: " use_combination
        if [[ -z "$use_combination" || "$use_combination" =~ ^[Yy]$ ]]; then
          input_profile="$recommended_base,$input_profile"
          print_info "Using '$input_profile' combination"
        fi
      fi
    # Check if this is a base profile that could have add-ons
    elif [[ "$input_profile" == "desktop" ]]; then
      # Build a list of available add-ons
      local addon_options=""
      local addon_list=""
      
      for addon in "${!STANDALONE_PROFILES[@]}"; do
        IFS=':' read -r base_profile description <<< "${STANDALONE_PROFILES[$addon]}"
        if [[ "$base_profile" == "$input_profile" ]]; then
          [[ -n "$addon_options" ]] && addon_options+=", "
          addon_options+="$addon"
          addon_list+="$addon "
        fi
      done
      
      if [[ -n "$addon_options" ]]; then
        local add_de
        read -p "You've selected only the '$input_profile' base profile. Would you like to add a desktop environment ($addon_options)? [y/N]: " add_de
        if [[ "$add_de" =~ ^[Yy]$ ]]; then
          local de_choice
          read -p "Enter desktop environment ($addon_options): " de_choice
          
          # Check if the choice is valid
          if [[ "$addon_list" == *"$de_choice "* ]]; then
            input_profile="$input_profile,$de_choice"
            print_info "Using '$input_profile' combination"
          else
            print_warning "Invalid choice. Continuing with just the '$input_profile' profile."
          fi
        fi
      fi
    else
      print_info "Using '$input_profile' profile."
    fi
    
    # Validate the profile
    if validate_profile "$input_profile"; then
      PROFILE="$input_profile"
    else
      print_warning "Invalid profile. Using existing profile: $PROFILE"
    fi
  else
    # No input, keep the current profile
    if [[ -z "$PROFILE" ]]; then
      print_info "Building without a profile."
    else
      print_info "Using existing profile: $PROFILE"
    fi
  fi
}

# Handle OBS package selection
handle_obs_selection() {
  display_config_header "OBS-hosted packages for systemd" "Sometimes ${BOLD}ParticleOS${RESET} adopts ${BOLD}systemd${RESET} features as soon as they get merged into ${BOLD}systemd${RESET} without waiting for an official release.
As such, to build with the current ${BOLD}systemd${RESET} source, you can include the ${YELLOW}obs${RESET} profile to use packages hosted on OBS (openSUSE Build Services).
For more info on alternatively building ${BOLD}systemd${RESET} from source, please visit ${CYAN}https://github.com/systemd/particleos${RESET}"

  # Check if obs is already in the profile
  if [[ $OBS_REPOS == true ]]; then
    echo -e "The ${BOLD}obs${RESET} profile is currently ${GREEN}selected (default)${RESET}."
  else
    echo -e "The ${BOLD}obs${RESET} profile is currently ${YELLOW}not selected${RESET}."
  fi

  # Get user input for OBS inclusion
  local default_char
  if $OBS_REPOS; then
    default_char="Y/n"
  else
    default_char="y/N"
  fi
  
  read -p "Include obs profile? [$default_char]: " answer_obs

  # Default to current selection if no input is given
  if [[ -z "$answer_obs" ]]; then
    answer_obs=$(if $OBS_REPOS; then echo "y"; else echo "n"; fi)
  fi

  if [[ "$answer_obs" =~ ^[Yy]$ ]]; then
    OBS_REPOS=true
    print_info "Using OBS repositories for systemd."
    if [[ ",${PROFILE}," != *",obs,"* && "$PROFILE" != "obs" ]]; then
      # Add obs to the profile if not already there
      if [[ -z "$PROFILE" ]]; then
        PROFILE="obs"
      else
        PROFILE="${PROFILE},obs"
      fi
    fi
  else
    OBS_REPOS=false
    print_info "Using local tooling or current packages for systemd."
    
    # Remove obs from profile if it's there
    if [[ "$PROFILE" == "obs" ]]; then
      PROFILE=""
    elif [[ "$PROFILE" == *",obs" ]]; then
      PROFILE="${PROFILE%,obs}"
    elif [[ "$PROFILE" == "obs,"* ]]; then
      PROFILE="${PROFILE#obs,}"
    elif [[ "$PROFILE" == *",obs,"* ]]; then
      PROFILE=$(echo "$PROFILE" | sed 's/,obs,/,/g')
    fi
  fi
}

# Handle root password configuration
handle_root_password() {
  display_config_header "Root Password Configuration (optional)" "A default root password can be configured for the resulting image."
  
  # Get and verify password
  while true; do
    read -s -p "Enter a root password (or press Enter to skip): " pass1
    echo
    if [[ -z "$pass1" ]]; then
      print_info "No root password set."
      ROOT_PASSWORD=""
      break
    fi
    
    # Confirm password
    read -s -p "Confirm root password: " pass2
    echo
    if [[ "$pass1" == "$pass2" ]]; then
      ROOT_PASSWORD="$pass1"
      print_success "Root password confirmed."
      break
    else
      print_error "Passwords do not match. Please try again, or press Enter to skip."
    fi
  done
}

# Handle cleaning options
handle_cleaning_options() {
  display_config_header "Cleaning Option for mkosi Build" "Configure if mkosi will cleanup files from prior builds:"

  # Determine current selection based on CLEAN_MKOSI value
  local current_clean_option
  case "$CLEAN_MKOSI" in
    "-ff clean") current_clean_option="3" ;;
    "-ff") current_clean_option="2" ;;
    "") current_clean_option="4" ;;
    *) current_clean_option="1" ;;  # Default for "-f" or anything else
  esac

  # Display options
  print_option "1" "Clean image cache only [-f]" "$current_clean_option" "1"
  print_option "2" "Clean image cache & all packages [-ff]" "$current_clean_option" ""
  print_option "3" "Full clean [-ff clean]" "$current_clean_option" ""
  print_option "4" "No cleaning option" "$current_clean_option" ""

  read -p "Enter your choice [1-4]: " cleaning_choice
  
  # Process cleaning choice
  case "$cleaning_choice" in
    2)
      CLEAN_MKOSI="-ff"
      print_info "Image cache and package clean configured."
      ;;
    3)
      CLEAN_MKOSI="-ff clean"
      print_info "Full clean configured."
      ;;
    4)
      CLEAN_MKOSI=""
      print_warning "No clean configured."
      ;;
    1|"")
      CLEAN_MKOSI="-f"
      print_info "Image cache clean configured."
      ;;
    *)
      # Default for anything else - keep current setting
      case "$CLEAN_MKOSI" in
        "-ff clean") print_info "Full clean configured." ;;
        "-ff") print_info "Image cache and package clean configured." ;;
        "") print_info "No clean configured." ;;
        *) print_info "Image cache clean configured." ;; 
      esac
      ;;
  esac
}

# Display configuration summary
print_config_summary() {
  echo -e "  • ${BOLD}Architecture:${RESET}      $ARCHITECTURE"
  echo -e "  • ${BOLD}Distribution:${RESET}      $DISTRIBUTION"
  echo -e "  • ${BOLD}Profile:${RESET}           $(if [[ -n "$PROFILE" ]]; then echo "$PROFILE"; else echo "[None]"; fi)"
  echo -e "  • ${BOLD}Root Password:${RESET}     $(if [[ -n "$ROOT_PASSWORD" ]]; then echo "[Set]"; else echo "[Not Set]"; fi)"
  # Get obs status directly from the profile
  local obs_status="Disabled"
  if [[ ",${PROFILE}," == *",obs,"* || "$PROFILE" == "obs" ]]; then
    obs_status="Enabled"
  fi
  echo -e "  • ${BOLD}OBS Packages:${RESET}      $obs_status"
  echo -e "  • ${BOLD}Debug Mode:${RESET}        $(if $DEBUG_MODE; then echo "Enabled"; else echo "Disabled"; fi)"
  echo -e "  • ${BOLD}Cleanup Options:${RESET}   $(if [[ -n "$CLEAN_MKOSI" ]]; then echo "$CLEAN_MKOSI"; else echo "[None]"; fi)"
}

# Confirm selections function
confirm_selections() {
  print_header "Configuration Summary"
  print_config_summary
  
  read -p "Are these settings correct? [Y/n]: " answer
  # Accept both empty input and 'y'/'Y' as confirmation
  if [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; then
    return 0  # Settings confirmed
  else
    return 1  # Need to reconfigure
  fi
}

# Main interactive configuration function - refactored for modularity
configure_interactively() {
  # Set a local trap to exit on Ctrl+C during interactive config
  trap 'echo -e "\n${YELLOW}Interactive configuration aborted by user.${RESET}"; exit 1' INT

  print_header "ParticleOS Build Configuration"
  
  # Process OBS profile before we start
  if [[ ",${PROFILE}," == *",obs,"* || "$PROFILE" == "obs" ]]; then
    # Set the flag
    OBS_REPOS=true
    
    # Handle different cases of obs placement
    if [[ "$PROFILE" == "obs" ]]; then
      # obs is the only profile
      PROFILE=""
    elif [[ "$PROFILE" == obs,* ]]; then
      # obs is at the beginning
      PROFILE="${PROFILE#obs,}"
    elif [[ "$PROFILE" == *,obs ]]; then
      # obs is at the end
      PROFILE="${PROFILE%,obs}"
    else
      # obs is in the middle
      PROFILE=$(echo "$PROFILE" | sed 's/,obs,/,/g')
    fi
  fi
  
  # Configuration loop - continue until user confirms selections
  while true; do
    # Handle each configuration section
    handle_architecture_selection
    handle_distribution_selection
    handle_profile_selection
    handle_obs_selection
    handle_root_password
    handle_cleaning_options
    
    # Confirm selections
    if confirm_selections; then
      break
    else
      print_warning "Reconfiguring interactive options..."
    fi
  done
}
# ════════════════════════════ Parse Arguments ═══════════════════════════════
# Helper function to extract option value
get_option_value() {
  local option="$1"
  local arg="$2"
  local next_arg="$3"
  
  # Handle --option=value format
  if [[ "$arg" == "$option="* ]]; then
    echo "${arg#*=}"
    return 0
  # Handle --option value format
  elif [[ "$arg" == "$option" ]]; then
    if [[ -z "$next_arg" || "$next_arg" == -* ]]; then
      print_error "Missing argument for $option. Usage: $option=<value> or $option <value>"
      return 1
    fi
    echo "$next_arg"
    return 2  # Signal that we consumed the next argument
  fi
  
  return 1  # Not our option or invalid format
}

# Parse option with validation
# Returns 0 if successful, 1 if error, 2 if next argument consumed
parse_validated_option() {
  local option="$1"        # Option name (e.g., --arch)
  local arg="$2"           # Current argument
  local next_arg="$3"      # Next argument
  local validator="$4"     # Validation function name
  local var_name="$5"      # Global variable to set
  local normalizer="${6:-}" # Optional normalizer function
  
  # Get option value
  local value
  value=$(get_option_value "$option" "$arg" "$next_arg")
  local retval=$?
  
  if [[ $retval -eq 1 ]]; then  # Error or not our option
    return 1
  fi
  
  # Apply normalizer if provided
  if [[ -n "$normalizer" ]]; then
    value=$($normalizer "$value")
  fi
  
  # Validate the value
  if ! $validator "$value"; then
    return 1
  fi
  
  # Set the global variable
  # Use eval to handle variable indirection
  eval "$var_name=\"$value\""
  
  # Return 2 if we consumed the next argument
  if [[ $retval -eq 2 ]]; then
    return 2
  fi
  
  return 0
}


# Help display with formatting
show_help() {
  cat <<EOF
$(print_styled "header" "ParticleOS Build Script")

A tool to configure and build Linux images using mkosi.

$(print_styled "subheader" "Usage")
  $0 [options]

$(print_styled "subheader" "Mkosi Options")
  --arch [ARCH]             Architecture (x86_64, aarch64, etc.)
  --dist [DIST], -d         Distribution (fedora, arch, debian, etc.)
  --profile [PROFILE]       Profile (desktop,gnome; desktop,kde; obs)
  --root-password [PASS]    Set root password for mkosi to load
  --debug                   Show debug output during the mkosi build
  -f                        Clean image cache before build
  -ff                       Clean image and package cache before build
  -w                        Clean build directory before build
  
$(print_styled "subheader" "Script Control")
  --interactive, -i          Interactive configuration mode
  --fullscreen, -fs          Run in full-screen terminal mode
  --confirm, -c              Force confirmation prompt before build
  --save-config [FILE]       Save current configuration to file
  --load-config [FILE]       Load configuration from file
  --help, -h                 Show this help message
  
$(print_styled "subheader" "Examples")
  $0                   Run in interactive mode
  $0 -d fedora --profile desktop,gnome
  $0 --arch=x86_64 -d=arch --profile desktop,kde --debug
EOF
}

# Parse and process command line arguments
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fullscreen|-fs)
        clear
        FULLSCREEN_MODE=true
        ;;
      
      --arch=*|--arch)
        if parse_validated_option "--arch" "$1" "$2" "validate_architecture" "ARCHITECTURE" "normalize_architecture"; then
          [[ $? -eq 2 ]] && shift
        else
          exit 1
        fi
        ;;
        
      --dist=*|--dist|-d)
        local option="--dist"
        [[ "$1" == "-d" ]] && option="-d"
        
        if parse_validated_option "$option" "$1" "$2" "validate_distribution" "DISTRIBUTION"; then
          [[ $? -eq 2 ]] && shift
        else
          exit 1
        fi
        ;;
        
      --profile=*|--profile)
        if parse_validated_option "--profile" "$1" "$2" "validate_profile" "PROFILE"; then
          [[ $? -eq 2 ]] && shift
        else
          exit 1
        fi
        ;;
        
      --root-password=*|--root-password)
        local value
        value=$(get_option_value "--root-password" "$1" "$2")
        local retval=$?
        
        if [[ $retval -eq 1 ]]; then  # Error or not our option
          exit 1
        elif [[ $retval -eq 2 ]]; then  # Consumed next argument
          shift
        fi
        
        ROOT_PASSWORD="$value"
        ;;
        
      --debug)
        DEBUG_MODE=true
        ;;
        
      --interactive|-i)
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
        
      --confirm|-c)
        FORCE_CONFIRM=true
        ;;

      --save-config)
        if [[ $# -gt 1 && "$2" != -* ]]; then
          save_configuration "$2"
          shift
        else
          save_configuration
        fi
        ;;
        
      --load-config)
        if [[ $# -gt 1 && "$2" != -* ]]; then
          load_configuration "$2"
          shift
        else
          load_configuration
        fi
        ;;
        
      --help|-h)
        show_help
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

# ════════════════════════════ Build Functions ═══════════════════════════════
# Execute mkosi build command
execute_mkosi_build() {
  local mkosi_bin="$1"
  local build_log="$2"
  local status_file="$3"
  # Arguments for mkosi should start from the 4th argument
  local mkosi_args=("${@:4}")
  
  print_info "Building with: $mkosi_bin ${mkosi_args[*]}"
  echo
  
  # Check if script command is available for full color logging
  if command_exists script; then
    print_info "Using 'script' utility for mkosi output & logging"
    
    # Set environment variables to encourage color output
    export FORCE_COLOR=1
    export CLICOLOR_FORCE=1
    export SYSTEMD_COLORS=1
    
    # Execute mkosi build with script for full color
    (
      set +e
      
      # Script maintains terminal connection for color
      script -qec "$mkosi_bin ${mkosi_args[*]}" /dev/null | tee "$build_log"
      
      # Get the exit status
      echo ${PIPESTATUS[0]} > "$status_file"
      
      set -e
    )
  else
    print_info "Using process substitution for mkosi output & logging (limited color)"
    
    # Set environment variables to encourage color output
    export FORCE_COLOR=1
    export CLICOLOR_FORCE=1
    export SYSTEMD_COLORS=1
    
    # Execute mkosi build with process substitution
    (
      # Use set +e to prevent the subshell from exiting on error
      set +e
      
      # Execute the command with process substitution
      # This keeps the terminal connection alive for color output
      "$mkosi_bin" "${mkosi_args[@]}" 2>&1 > >(tee "$build_log")
      
      # Store the exit status directly from the mkosi command
      echo $? > "$status_file"
      
      # Turn error handling back on
      set -e
    )
  fi
}

# Handle build results and diagnostics
handle_build_result() {
  local build_status="$1"
  local build_log="$2"
  local build_duration="$3"
  
  if [[ $build_status -ne 0 ]]; then
    local error_log="${SCRIPT_DIR}/mkosi-build-error-$(date +%Y%m%d-%H%M%S).log"
    cp "$build_log" "$error_log"
    print_error "Build failed with code $build_status - error log saved to $error_log"
    
    # Extract common errors from the log for quick diagnosis
    print_info "Analyzing build failure..."
    if grep -q "No space left on device" "$build_log"; then
      print_error "Build failed due to insufficient disk space"
    elif grep -q "Could not resolve" "$build_log"; then
      print_error "Build failed due to network connectivity issues"
    elif grep -q "Permission denied" "$build_log"; then
      print_error "Build failed due to permission issues"
    elif grep -q "are too open" "$build_log"; then
      print_error "Build failed due to insecure file permissions"
      grep -A 1 "are too open" "$build_log"
    fi
    
    exit 1
  fi
  
  print_success "mkosi build completed successfully in $(( build_duration / 60 )) minutes and $(( build_duration % 60 )) seconds!"
  
  # Verify the output image exists
  if ! ls -la "${SCRIPT_DIR}"/mkosi.output/*.raw 2>/dev/null | grep -q ".raw"; then
    print_warning "Build appeared to succeed but no .raw image file was found"
  else
    print_info "Output images:"
    ls -lh "${SCRIPT_DIR}"/mkosi.output/*.raw 2>/dev/null
  fi
}

# Run mkosi to build the image
run_mkosi() {
  print_header "Building ParticleOS Image with mkosi"
  
  # Verify mkosi directory and executable 
  if [[ ! -d "${SCRIPT_DIR}/${MKOSI_DIR}" ]]; then
    print_error "mkosi directory not found at ${SCRIPT_DIR}/${MKOSI_DIR}"
    print_info "Please run the script again to clone the repository"
    exit 1
  fi
  
  local mkosi_bin="${MKOSI_DIR}/bin/mkosi"
  if [[ ! -x "$mkosi_bin" ]]; then
    print_error "mkosi executable not found at $mkosi_bin"
    exit 1
  fi
  
  # Setup secure boot keys
  if ! setup_secure_boot_keys; then
    print_error "Failed to set up secure boot keys"
    exit 1
  fi
  
  # Set up root password if specified
  if ! setup_root_password; then
    print_warning "Root password setup failed, continuing without root password"
  fi
  
  # Create a timestamp for build start
  local build_start_seconds
  build_start_seconds=$(date +%s)
  print_info "Build started at $(date '+%Y-%m-%d %H:%M:%S')"
  
  # Create build log file
  local build_log
  build_log=$(create_temp_file "mkosi-build-log")
  print_info "Build log will be saved to $build_log"
  
  # Build command line arguments
  local mkosi_args=("-d" "$DISTRIBUTION")
  
  # Add optional parameters (except clean)
  [[ -n "$PROFILE" ]] && mkosi_args+=("--profile" "$PROFILE")
  [[ "$DEBUG_MODE" == true ]] && mkosi_args+=("--debug")
  
  # Handle cleaning options
  local do_separate_clean=false
  local clean_args=""
  
  if [[ "$CLEAN_MKOSI" == *"clean"* ]]; then
    # Extract flags for clean command (-f or -ff)
    clean_args="${CLEAN_MKOSI%% *}"
    do_separate_clean=true
    
    # For the main build command, don't include "clean"
    [[ -n "$clean_args" ]] && mkosi_args+=("$clean_args")
  else
    # For normal operation, just add the clean flags if any
    [[ -n "$CLEAN_MKOSI" ]] && mkosi_args+=($CLEAN_MKOSI)
  fi
  
  [[ "$CLEAN_BUILD" == true ]] && mkosi_args+=("-w")
  
  # Create a temporary file for exit status
  local status_file
  status_file=$(create_temp_file "mkosi-status")
  
  # Run the clean command first if needed
  if $do_separate_clean; then
    print_info "Executing clean operation with: $mkosi_bin $clean_args clean"
    
    # Execute clean command
    execute_mkosi_build "$mkosi_bin" "$clean_args" "clean" "$build_log" "$status_file"
    
    echo
    print_info "Clean operation completed, proceeding with build..."
  fi
  
  # Execute main build
  execute_mkosi_build "$mkosi_bin" "$build_log" "$status_file" "${mkosi_args[@]}"
  
  # Retrieve the exit status from temp file
  local build_status=1
  if [[ -f "$status_file" ]]; then
    build_status=$(cat "$status_file")
  else
    print_error "Status file not found, assuming build failed"
  fi
  
  # Calculate build duration
  local build_end_seconds
  local build_duration
  build_end_seconds=$(date +%s)
  build_duration=$((build_end_seconds - build_start_seconds))
  
  # Handle build result
  handle_build_result "$build_status" "$build_log" "$build_duration"
}

# ═════════════════════════════ Main Function ═══════════════════════════════
# Check if script is running with sudo/run0/root and warn if appropriate
check_root_privileges() {
  if [[ $EUID -eq 0 ]]; then
    print_warning "This script is running with root privileges"
    print_warning "While some operations might need run0, running the entire script as root is not required"
    print_warning "mkosi will use run0 for operations that require elevated privileges"
    
    read -p "Continue running as root? [y/N]: " root_confirm
    if [[ ! "$root_confirm" =~ ^[Yy]$ ]]; then
      print_info "Exiting script to be run without root access"
      exit 0
    fi
  fi
}

# Create a lock file to prevent multiple instances running simultaneously
acquire_lock() {
  local lock_file="${SCRIPT_DIR}/.particleos-build.lock"
  
  # Check if another instance is already running
  if [[ -f "$lock_file" ]]; then
    local pid
    pid=$(cat "$lock_file" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      print_error "Another instance of this script (PID: $pid) is already running"
      print_info "If you're sure no other instance is running, delete the lock file:"
      print_info "  rm ${lock_file}"
      exit 1
    else
      print_warning "Found stale lock file from a previous run"
      rm -f "$lock_file"
    fi
  fi
  
  # Create the lock file with PID
  echo $$ > "$lock_file"
  
  # Add to cleanup
  track_file "$lock_file"
}

# Log execution with timestamp
log_execution() {
  local log_file="${SCRIPT_DIR}/particleos-builds.log"
  local timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  local cmd_args="$*"
  local host_info=""
  
  # Get hostname with fallback
  if command_exists hostname; then
    host_info="$(whoami)@$(hostname)"
  else
    # Use alternative methods to get host information
    if [ -f /etc/hostname ]; then
      host_info="$(whoami)@$(cat /etc/hostname)"
    elif [ -f /proc/sys/kernel/hostname ]; then
      host_info="$(whoami)@$(cat /proc/sys/kernel/hostname)"
    else
      host_info="$(whoami)@unknown-host"
    fi
  fi
  
  {
    echo "==============================================="
    echo "Build started: $timestamp"
    echo "Command: $0 $cmd_args"
    echo "User: $host_info"
    echo "System: $(uname -a)"
    echo "==============================================="
  } >> "$log_file"
}

main() {
  # Store start time for build duration calculation
  local start_time
  start_time=$(date +%s)
  
  # Check for root/sudo usage
  check_root_privileges
  
  # Acquire lock to prevent multiple simultaneous runs
  acquire_lock
  
  # Log this execution with args
  log_execution "$@"
  
  local args_count=$#
  
  # Check dependencies before anything else
  check_dependencies
  
  # Parse command line arguments
  parse_args "$@"

  if $FULLSCREEN_MODE && [ -f "./particleos-render.sh" ]; then
      source ./particleos-render.sh
      reset_colors
      clear
  fi

  # Enable interactive mode if no args provided or only fullscreen mode specified
  if [[ $args_count -eq 0 ]] || [[ $args_count -eq 1 && $FULLSCREEN_MODE == true ]]; then
    INTERACTIVE=true
  fi
  
  # Auto-detect OBS profile in non-interactive mode
  if ! $INTERACTIVE; then
    auto_detect_obs_profile
  fi
  
  # Interactive configuration process
  if $INTERACTIVE; then
    # Create a safe-state backup of current config in case user cancels
    local arch_backup="$ARCHITECTURE"
    local dist_backup="$DISTRIBUTION"
    local profile_backup="${PROFILE:-}"
    
    configure_interactively
  elif [[ "$FORCE_CONFIRM" == true ]]; then
    # Force confirmation if requested
    print_header "Final Configuration Summary"
    print_config_summary

    read -p "Are you sure you want to proceed? [y/N]: " force_confirm_answer
    if [[ ! "$force_confirm_answer" =~ ^[Yy]$ ]]; then
      echo "Build cancelled. Exiting."
      exit 0
    fi
  else
    # Display final configuration summary before proceeding
    print_header "Final Configuration Summary"
    print_config_summary
  fi
  
  # Setup and run mkosi
  setup_mkosi
  run_mkosi
  
  # Calculate total execution time
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))
  local minutes=$((duration / 60))
  local seconds=$((duration % 60))
  
  print_success "ParticleOS build completed successfully in ${minutes}m ${seconds}s!"
  
  # Provide next steps guidance
  display_next_steps
}


# Display next steps after successful build
display_next_steps() {
  echo
  print_header "Next Steps"
  echo -e "To install your ParticleOS image to a USB drive, use:"
  echo -e "  ${CYAN}mkosi/bin/mkosi burn /dev/sdX${RESET}"
  echo -e "  ${YELLOW}(Replace sdX with your actual USB device)${RESET}"
  echo
  echo -e "To boot the image in a VM, use:"
  echo -e "  ${CYAN}mkosi/bin/mkosi vm${RESET}"
  echo
  echo -e "For more information, visit: ${CYAN}https://github.com/systemd/particleos${RESET}"
}

# Start execution with some basic safeguards
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Script is being executed directly, not sourced
  main "$@"
else
  # Script is being sourced, not executed
  print_warning "This script is meant to be executed, not sourced"
  print_info "Please run: ${BOLD}bash $0${RESET}"
  return 1
fi