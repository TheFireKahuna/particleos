#!/usr/bin/env bash
# ParticleOS Terminal Visualization

###############################################################################
# Terminal utilities and setup
###############################################################################

particleos_clear_screen() { printf "\033[2J\033[H"; }
particleos_hide_cursor() { printf "\033[?25l"; }
particleos_show_cursor() { printf "\033[?25h"; }
particleos_get_term_size() { 
particleos_reset_colors() { printf "\033[0m\033[49m"; }
  # Get terminal size reliably
  if [[ -n "$LINES" && -n "$COLUMNS" ]]; then
    PARTICLEOS_LINES=$LINES
    PARTICLEOS_COLUMNS=$COLUMNS
  elif [[ -t 0 && -t 1 ]]; then
    if size=$(stty size 2>/dev/null); then
      PARTICLEOS_LINES=${size% *}
      PARTICLEOS_COLUMNS=${size#* }
    else
      PARTICLEOS_LINES=$(tput lines 2>/dev/null || echo 24)
      PARTICLEOS_COLUMNS=$(tput cols 2>/dev/null || echo 80)
    fi
  else
    PARTICLEOS_LINES=24
    PARTICLEOS_COLUMNS=80
  fi
  
  [[ "$PARTICLEOS_LINES" =~ ^[0-9]+$ ]] || PARTICLEOS_LINES=24
  [[ "$PARTICLEOS_COLUMNS" =~ ^[0-9]+$ ]] || PARTICLEOS_COLUMNS=80
  
  export PARTICLEOS_LINES PARTICLEOS_COLUMNS
}
particleos_position() { printf "\033[${2};${1}H"; }
particleos_reset_term_attr() { printf "\033[0m"; }

# Store original terminal state
particleos_store_terminal_state() {
  PARTICLEOS_ORIGINAL_TTY_SETTINGS=$(stty -g 2>/dev/null || echo "")
  
  particleos_get_term_size
  
  trap 'particleos_get_term_size' WINCH
}

# Restore terminal to original state
particleos_restore_terminal_state() {
  trap - WINCH
  
  if [[ -n "$PARTICLEOS_ORIGINAL_TTY_SETTINGS" ]]; then
    stty "$PARTICLEOS_ORIGINAL_TTY_SETTINGS" 2>/dev/null
  fi
  
  printf "\033[?25h"
  
  printf "\033[0m"
}

# Save the specified lines from the terminal
particleos_save_screen_region() {
    local start_line=$1
    local end_line=$2
    local content=""
    
    printf "\033[s"
    
    for ((i=start_line; i<=end_line; i++)); do
        particleos_position 1 "$i"
        content+="$(tput el)$(cat)"$'\n'
    done
    
    printf "\033[u"
    
    echo "$content"
}

# Clean up and preserve the title area
particleos_cleanup() {
  
  local title_content=$(particleos_save_screen_region 1 15)
  
  printf "\033[0m"
  
  particleos_show_cursor
  
  
  IFS=$'\n'
  local line_num=1
  for line in $title_content; do
    particleos_position 1 "$line_num"
    echo -n "$line"
    ((line_num++))
  done
  unset IFS
  
  particleos_reset_term_attr
  particleos_position 1 5
  
  particleos_restore_terminal_state
  particleos_reset_colors

  trap - INT TERM EXIT
  
  return 0
}

# Get terminal dimensions
LINES=$(tput lines)
COLUMNS=$(tput cols)

# Define the preserved region
PRESERVE_WIDTH=40
PRESERVE_HEIGHT=5
###############################################################################
# Colors
###############################################################################

PS_BLACK="\033[30m"       PS_RED="\033[31m"        PS_GREEN="\033[32m"       PS_YELLOW="\033[33m"
PS_BLUE="\033[34m"        PS_MAGENTA="\033[35m"    PS_CYAN="\033[36m"        PS_WHITE="\033[37m"
PS_B_BLACK="\033[90m"     PS_B_RED="\033[91m"      PS_B_GREEN="\033[92m"     PS_B_YELLOW="\033[93m"
PS_B_BLUE="\033[94m"      PS_B_MAGENTA="\033[95m"  PS_B_CYAN="\033[96m"      PS_B_WHITE="\033[97m"
PS_RESET="\033[0m"        PS_BOLD="\033[1m"        PS_BG_BLACK="\033[40m"

###############################################################################
# Overlap tracking
###############################################################################

declare -A ELEMENT_MAP

particleos_register_element() {
  local name=$1 x=$2 y=$3 width=$4 height=$5
  for ((i=0; i<height; i++)); do
    for ((j=0; j<width; j++)); do
      ELEMENT_MAP["$((x+j)),$((y+i))"]=$name
    done
  done
}

###############################################################################
# Drawing primitives
###############################################################################

particleos_draw_char() {
  particleos_position "$1" "$2"
  printf "$3$4$PS_RESET"
}

particleos_draw_text() {
  particleos_position "$1" "$2"
  printf "$3$4$PS_RESET"
}

particleos_animated_text() {
  local x=$1 y=$2 color=$3 text=$4 delay=${5:-0.02}
  particleos_position "$x" "$y"
  printf "$color"
  for ((i=0; i<${#text}; i++)); do
    printf "${text:$i:1}"
    sleep $delay
  done
  printf "$PS_RESET"
}

particleos_clear_area() {
  local x=$1 y=$2 width=$3 height=$4
  local space=$(printf ' %.0s' $(seq 1 $width))
  for ((i=0; i<height; i++)); do
    particleos_position "$x" "$((y+i))"
    printf "$PS_BG_BLACK$space$PS_RESET"
  done
}

###############################################################################
# Boxes and lines
###############################################################################

particleos_draw_box() {
  local x=$1 y=$2 width=$3 height=$4 color=$5 style=$6 title=$7
  local tl="╭" tr="╮" bl="╰" br="╯" h="─" v="│"
  case "$style" in
    dashed) h="┄" v="┊" ;;
    double) tl="╔" tr="╗" bl="╚" br="╝" h="═" v="║" ;;
    sharp)  tl="┌" tr="┐" bl="└" br="┘" h="─" v="│" ;;
  esac
  particleos_position "$x" "$y"; printf "$color$tl"
  for ((i=1; i<width-1; i++)); do
    printf "$h"
    [ $((i % 5)) -eq 0 ] && sleep 0.01
  done
  printf "$tr$PS_RESET"
  for ((i=1; i<height-1; i++)); do
    particleos_position "$x" "$((y+i))"
    printf "$color$v$PS_RESET"
    particleos_position "$((x+width-1))" "$((y+i))"
    printf "$color$v$PS_RESET"
    [ $((i % 5)) -eq 0 ] && sleep 0.01
  done
  particleos_position "$x" "$((y+height-1))"
  printf "$color$bl"
  for ((i=1; i<width-1; i++)); do
    printf "$h"
    [ $((i % 5)) -eq 0 ] && sleep 0.01
  done
  printf "$br$PS_RESET"
  if [ -n "$title" ]; then
    local title_len=${#title}
    local title_pos=$((x + (width - title_len) / 2))
    particleos_position "$title_pos" "$y"
    printf "$color$title$PS_RESET"
    sleep 0.01
  fi
  particleos_register_element "box_${x}_${y}" "$x" "$y" "$width" "$height"
}

particleos_draw_line() {
  local x1=$1 y1=$2 x2=$3 y2=$4 color=$5 style=$6
  local dx=$((x2 - x1))
  local dy=$((y2 - y1))
  local steps=$((dx > dy ? dx : dy))
  [ $steps -lt 0 ] && steps=$((0 - steps))
  [ $steps -eq 0 ] && steps=1
  local char="•"
  [ "$style" = "dashed" ] && char="·"
  for ((i=0; i<=steps; i++)); do
    local px=$((x1 + dx * i / steps))
    local py=$((y1 + dy * i / steps))
    particleos_draw_char "$px" "$py" "$color" "$char"
    [ $((i % 5)) -eq 0 ] && sleep 0.01
  done
  particleos_draw_char "$x2" "$y2" "$color" "●"
}

###############################################################################
# Particle generation
###############################################################################

particleos_spawn_particles() {
  local x=$1 y=$2 radius=$3 count=$4 color=$5
  local particles=("·" "•" "○" "✦" "*")
  for ((i=0; i<count; i++)); do
    local dx=$((RANDOM % (2*radius) - radius))
    local dy=$((RANDOM % (2*radius) - radius))
    local px=$((x + dx))
    local py=$((y + dy))
    if [ $px -gt 2 ] && [ $px -lt $((COLUMNS-2)) ] &&
       [ $py -gt 2 ] && [ $py -lt $((LINES-2)) ] &&
       [ -z "${ELEMENT_MAP["$px,$py"]}" ]; then
      local particle=${particles[$((RANDOM % ${#particles[@]}))]}
      particleos_draw_char "$px" "$py" "$color" "$particle"
    fi
    [ $((i % 3)) -eq 0 ] && sleep 0.01
  done
}

particleos_spawn_box_particles() {
  local x=$1 y=$2 width=$3 height=$4 color=$5
  local particles=("·" "•" "○" "✦" "*")
  local area=$((width * height))
  local count=$((area / 10))
  [[ $count -lt 5 ]] && count=5
  [[ $count -gt 40 ]] && count=40
  local text_margin_x=$((width / 4))
  local text_margin_y=$((height / 3))
  local safe_x1=$((x + text_margin_x))
  local safe_x2=$((x + width - text_margin_x))
  local safe_y1=$((y + text_margin_y))
  local safe_y2=$((y + height - text_margin_y))
  for ((i=0; i<count; i++)); do
    local px=$((x + 1 + RANDOM % (width-2)))
    local py=$((y + 1 + RANDOM % (height-2)))
    if ! ([ $px -ge $safe_x1 ] && [ $px -le $safe_x2 ] &&
          [ $py -ge $safe_y1 ] && [ $py -le $safe_y2 ]); then
      local particle=${particles[$((RANDOM % ${#particles[@]}))]}
      particleos_draw_char "$px" "$py" "$color" "$particle"
      sleep 0.01
    fi
  done
}

particleos_reveal_element() {
  local x=$1 y=$2 width=$3 height=$4 color=$5 style=$6 title=$7
  particleos_clear_area "$x" "$y" "$width" "$height"
  particleos_draw_box "$x" "$y" "$width" "$height" "$PS_B_BLACK" "$style" ""
  sleep 0.1
  particleos_spawn_box_particles "$x" "$y" "$width" "$height" "$color"
  particleos_draw_box "$x" "$y" "$width" "$height" "$color" "$style" "$title"
  if [ -n "$title" ]; then
    local title_len=${#title}
    local text_x=$((x + (width - title_len) / 2))
    local text_y=$((y + height / 2))
    particleos_animated_text "$text_x" "$text_y" "$color" "$title" 0.01
  fi
}

###############################################################################
# Main Visualization
###############################################################################

particleos_visualize() {
  particleos_get_term_size

  if [[ "$PARTICLEOS_COLUMNS" -lt 40 || "$PARTICLEOS_LINES" -lt 20 ]]; then
    read -n 1 -s > /dev/tty
  fi
  particleos_clear_screen
  particleos_hide_cursor
  
  local center_x=$((COLUMNS/2))
  local center_y=$((LINES/2))

  local border_x=$((center_x - 32))
  local border_y=2
  local usr_area_width=60
  local usr_area_height=20
  local output_width=10
  local output_height=3
  local iso_x=$((border_x - output_width - 10))
  local iso_y=$((border_y + 5))
  local net_x=$iso_x
  local net_y=$((iso_y + 7))
  local usb_x=$iso_x
  local usb_y=$((net_y + 7))
  local build_width=18
  local build_height=5
  local build_x=$((iso_x - build_width - 8))
  local build_y=$((net_y - 1))
  local mkosi_width=12
  local mkosi_height=3
  local mkosi_x=$((iso_x + 3 - build_width - 8))
  local mkosi_y=$((iso_y - 1))
  local usr_area_y=$((border_y + 3))
  local sysupdate_width=30
  local sysupdate_height=5
  local sysupdate_y=$((usr_area_y + usr_area_height + 1))
  local root_disk_width=45
  local root_disk_height=8
  local root_disk_x=$((center_x - root_disk_width/2 - 3))
  local root_disk_y=$((sysupdate_y + sysupdate_height + 5))
  local home_disk_width=35
  local home_disk_height=$root_disk_height
  local home_disk_x=$((root_disk_x + root_disk_width + 3))
  local home_disk_y=$root_disk_y
  local border_width=$((home_disk_x + home_disk_width + 15 - border_x))
  local usr_area_x=$(( border_x + (border_width - usr_area_width) / 2 ))
  local sysupdate_x=$((border_x + (border_width - sysupdate_width) / 4))
  local usr_box_width=16
  local usr_box_height=8
  local verity_box_width=14
  local verity_box_height=5
  local usr_spacing=6
  local total_usr_section_width=$((usr_box_width * 2 + usr_spacing))
  local usr_section_start_x=$((border_x + (border_width - total_usr_section_width) / 2))
  local usr_a_x=$usr_section_start_x
  local usr_a_y=$((usr_area_y + 10))
  local usr_b_x=$((usr_a_x + usr_box_width + usr_spacing))
  local usr_b_y=$usr_a_y
  local verity_a_x=$((usr_a_x + (usr_box_width - verity_box_width) / 2))
  local verity_a_y=$((usr_a_y - verity_box_height - 1))
  local verity_b_x=$((usr_b_x + (usr_box_width - verity_box_width) / 2))
  local verity_b_y=$verity_a_y
  local tpm_width=20
  local tpm_height=3
  local tpm_x=$((center_x - tpm_width/2))
  local tpm_y=$((root_disk_y + root_disk_height))
  local security_x=$((center_x - 20))
  local security_y=$((tpm_y + tpm_height + 3))
  local border_height=$((security_y + 1 - border_y))
  local title_x=1
  local title_y=1
  local title_width=35
  local title_height=3
  local disk_box_x=$((root_disk_x - 2))
  local disk_box_y=$((root_disk_y - 4))
  local disk_box_width=$(( (home_disk_x + home_disk_width + 2) - disk_box_x ))
  local disk_box_height=$((root_disk_height + 6))
  local desc_x=1
  local desc_y=2

  for ((i=0; i<80; i++)); do
    local px=$((RANDOM % (COLUMNS-10) + 5))
    local py=$((RANDOM % (LINES-10) + 5))
    local color_choice=$((RANDOM % 7))
    local color=""
    case $color_choice in
      0) color="$PS_WHITE" ;;
      1) color="$PS_WHITE" ;;
      2) color="$PS_WHITE" ;;
      3) color="$PS_WHITE" ;;
      4) color="$PS_WHITE" ;;
      5) color="$PS_WHITE" ;;
      6) color="$PS_WHITE" ;;
    esac
    local particles=("·" "•" "+" "*" "○")
    local particle=${particles[$((RANDOM % ${#particles[@]}))]}
    particleos_draw_char "$px" "$py" "$color" "$particle"
    [ $((i % 2)) -eq 0 ] && sleep 0.01
  done
  sleep 0.2

  particleos_animated_text "$((title_x))" "$((title_y))" "$PS_BOLD$PS_BLUE" "ParticleOS" 0.03
  sleep 0.3
  particleos_animated_text "$((title_x+10))" "$((title_y))" "$PS_CYAN" " - A hermetic, adaptive, immutable image-based OS for Linux." 0.01
  particleos_animated_text "$((title_x))" "$((desc_y))" "$PS_WHITE" "Press any key to continue..." 0.01

  particleos_reveal_element "$mkosi_x" "$mkosi_y" $mkosi_width $mkosi_height "$PS_YELLOW" "double" ""
  particleos_spawn_particles "$((mkosi_x+4))" "$((mkosi_y+1))" 3 10 "$PS_YELLOW"
  particleos_animated_text "$((mkosi_x+4))" "$((mkosi_y+1))" "$PS_YELLOW" "mkosi" 0.03
  sleep 0.2


  particleos_draw_line "$((mkosi_x+mkosi_width/2))" "$((mkosi_y+mkosi_height))" "$((mkosi_x+mkosi_width/2))" "$((build_y))" "$PS_YELLOW" "sharp"
  sleep 0.1

  particleos_reveal_element "$build_x" "$build_y" $build_width $build_height "$PS_GREEN" "solid" ""
  particleos_spawn_particles "$((build_x+4))" "$((build_y+2))" 4 10 "$PS_GREEN"
  particleos_animated_text "$((build_x+4))" "$((build_y+2))" "$PS_GREEN" "Build Image" 0.03
  sleep 0.3

  particleos_draw_line "$((build_x+build_width))" "$((build_y+1))" "$((iso_x-2))" "$((iso_y+1))" "$PS_GREEN" "sharp"
  sleep 0.05

  particleos_reveal_element "$iso_x" "$iso_y" $output_width $output_height "$PS_B_YELLOW" "solid" ""
  particleos_spawn_particles "$((iso_x+5))" "$((iso_y+1))" 4 10 "$PS_B_YELLOW"
  particleos_animated_text "$((iso_x+3))" "$((iso_y+1))" "$PS_B_YELLOW" "ISO" 0.03

  particleos_draw_line "$((build_x+build_width))" "$((build_y+2))" "$((net_x-2))" "$((net_y+1))" "$PS_GREEN" "sharp"
  sleep 0.05

  particleos_reveal_element "$net_x" "$net_y" $output_width $output_height "$PS_BLUE" "solid" ""
  particleos_spawn_particles "$((net_x+5))" "$((net_y+1))" 4 10 "$PS_BLUE"
  particleos_animated_text "$((net_x+3))" "$((net_y+1))" "$PS_BLUE" "NET" 0.03

  particleos_draw_line "$((build_x+build_width))" "$((build_y+3))" "$((usb_x-2))" "$((usb_y+1))" "$PS_GREEN" "sharp"
  sleep 0.05

  particleos_reveal_element "$usb_x" "$usb_y" $output_width $output_height "$PS_RED" "solid" ""
  particleos_spawn_particles "$((usb_x+5))" "$((usb_y+1))" 4 10 "$PS_RED"
  particleos_animated_text "$((usb_x+3))" "$((usb_y+1))" "$PS_RED" "USB" 0.03
  sleep 0.5

  for ((i=0; i<$((usr_area_x - (iso_x + output_width))); i+=2)); do
    particleos_draw_char "$((iso_x+output_width+i))" "$((iso_y+1))" "$PS_B_YELLOW" "·"
    [ $((i % 6)) -eq 0 ] && sleep 0.01
  done
  for ((i=0; i<$((usr_area_x - (net_x + output_width))); i+=2)); do
    particleos_draw_char "$((net_x+output_width+i))" "$((net_y+1))" "$PS_BLUE" "·"
    [ $((i % 6)) -eq 0 ] && sleep 0.01
  done
  for ((i=0; i<$((usr_area_x - (usb_x + output_width))); i+=2)); do
    particleos_draw_char "$((usb_x+output_width+i))" "$((usb_y+1))" "$PS_RED" "·"
    [ $((i % 6)) -eq 0 ] && sleep 0.01
  done

  particleos_draw_box "$usr_area_x" "$usr_area_y" "$usr_area_width" "$usr_area_height" "$PS_BLUE" "double" ""
  sleep 0.5
  particleos_animated_text $((border_x+(border_width-35)/2)) $((usr_area_y+2)) "$PS_B_CYAN" "Immutable /usr distribution & packages" 0.02
  sleep 0.1

  particleos_reveal_element "$usr_a_x" "$usr_a_y" $usr_box_width $usr_box_height "$PS_B_CYAN" "solid" ""
  particleos_animated_text "$((usr_a_x+5))" "$((usr_a_y+3))" "$PS_B_CYAN" "/usr (A)" 0.03

  for ((i=0; i<$((usr_a_y - (verity_a_y + verity_box_height))); i++)); do
    particleos_draw_char "$((verity_a_x+verity_box_width/2))" "$((usr_a_y-1-i))" "$PS_BLUE" "│"
  done
  particleos_reveal_element "$verity_a_x" "$verity_a_y" $verity_box_width $verity_box_height "$PS_BLUE" "solid" ""
  particleos_animated_text "$((verity_a_x+2))" "$((verity_a_y+2))" "$PS_BLUE" "verity (A)" 0.03

  for ((i=0; i<$((usr_b_x - (usr_a_x + usr_box_width))); i+=2)); do
    local dot_y=$((usr_a_y+usr_box_height/2))
    particleos_draw_char "$((usr_a_x+usr_box_width+i))" "$dot_y" "$PS_CYAN" "·"
  done

  particleos_reveal_element "$usr_b_x" "$usr_b_y" $usr_box_width $usr_box_height "$PS_CYAN" "solid" ""
  particleos_animated_text "$((usr_b_x+5))" "$((usr_b_y+3))" "$PS_CYAN" "/usr (b)" 0.03
  sleep 0.2

  for ((i=0; i<$((usr_b_y - (verity_b_y + verity_box_height))); i++)); do
    particleos_draw_char "$((verity_b_x+verity_box_width/2))" "$((usr_b_y-1-i))" "$PS_BLUE" "│"
  done
  particleos_reveal_element "$verity_b_x" "$verity_b_y" $verity_box_width $verity_box_height "$PS_BLUE" "solid" ""
  particleos_animated_text "$((verity_b_x+2))" "$((verity_b_y+2))" "$PS_BLUE" "verity (b)" 0.03
  sleep 0.5

  particleos_draw_line "$((border_x+(border_width/2)))" "$((usr_area_y+usr_area_height))" "$((border_x+(border_width/2)))" "$((disk_box_y))" "$PS_BLUE" "dashed"
  sleep 0.1
  particleos_draw_box $disk_box_x $disk_box_y $disk_box_width $disk_box_height "$PS_B_RED" "double" "Mutable /root & /home"

  for ((i=0; i<root_disk_width; i++)); do
    particleos_draw_char "$((root_disk_x+i))" "$((root_disk_y-1))" "$PS_RED" "─"
    particleos_draw_char "$((root_disk_x+i))" "$((root_disk_y+root_disk_height))" "$PS_RED" "─"
  done
  for ((i=0; i<root_disk_height+1; i++)); do
    particleos_draw_char "$((root_disk_x-1))" "$((root_disk_y+i-1))" "$PS_RED" "│"
    particleos_draw_char "$((root_disk_x+root_disk_width))" "$((root_disk_y+i-1))" "$PS_RED" "│"
  done
  particleos_draw_char "$((root_disk_x-1))" "$((root_disk_y-1))" "$PS_RED" "╭"
  particleos_draw_char "$((root_disk_x+root_disk_width))" "$((root_disk_y-1))" "$PS_RED" "╮"
  particleos_draw_char "$((root_disk_x-1))" "$((root_disk_y+root_disk_height))" "$PS_RED" "╰"
  particleos_draw_char "$((root_disk_x+root_disk_width))" "$((root_disk_y+root_disk_height))" "$PS_RED" "╯"
  particleos_animated_text "$((root_disk_x + 5))" "$((root_disk_y - 2))" "$PS_RED" "root (LUKS Encryption)" 0.02
  sleep 0.1

  local filesystem_height=3
  local var_width=10
  local etc_width=10
  local opt_width=10
  local fs_spacing=5
  local fs_total_width=$((var_width + etc_width + opt_width + 2*fs_spacing))
  local fs_start_x=$((root_disk_x + (root_disk_width - fs_total_width)/2))
  local var_x=$fs_start_x
  local var_y=$((root_disk_y + root_disk_height/2 - filesystem_height/2))
  local etc_x=$((var_x + var_width + fs_spacing))
  local etc_y=$var_y
  local opt_x=$((etc_x + etc_width + fs_spacing))
  local opt_y=$var_y

  particleos_reveal_element "$var_x" "$var_y" $var_width $filesystem_height "$PS_B_MAGENTA" "solid" ""
  particleos_spawn_particles "$((var_x+5))" "$((var_y+1))" 3 10 "$PS_B_MAGENTA"
  particleos_animated_text "$((var_x+3))" "$((var_y+1))" "$PS_B_MAGENTA" "/var" 0.03

  particleos_reveal_element "$etc_x" "$etc_y" $etc_width $filesystem_height "$PS_B_GREEN" "solid" ""
  particleos_spawn_particles "$((etc_x+5))" "$((etc_y+1))" 3 10 "$PS_B_GREEN"
  particleos_animated_text "$((etc_x+3))" "$((etc_y+1))" "$PS_B_GREEN" "/etc" 0.03

  particleos_reveal_element "$opt_x" "$opt_y" $opt_width $filesystem_height "$PS_B_BLUE" "solid" ""
  particleos_spawn_particles "$((opt_x+5))" "$((opt_y+1))" 3 10 "$PS_B_BLUE"
  particleos_animated_text "$((opt_x+3))" "$((opt_y+1))" "$PS_B_BLUE" "/opt" 0.03
  sleep 0.5

  for ((i=0; i<home_disk_width; i++)); do
    particleos_draw_char "$((home_disk_x+i))" "$((home_disk_y-1))" "$PS_MAGENTA" "─"
    particleos_draw_char "$((home_disk_x+i))" "$((home_disk_y+home_disk_height))" "$PS_MAGENTA" "─"
  done
  for ((i=0; i<home_disk_height+1; i++)); do
    particleos_draw_char "$((home_disk_x-1))" "$((home_disk_y+i-1))" "$PS_MAGENTA" "│"
    particleos_draw_char "$((home_disk_x+home_disk_width))" "$((home_disk_y+i-1))" "$PS_MAGENTA" "│"
  done
  particleos_draw_char "$((home_disk_x-1))" "$((home_disk_y-1))" "$PS_MAGENTA" "╭"
  particleos_draw_char "$((home_disk_x+home_disk_width))" "$((home_disk_y-1))" "$PS_MAGENTA" "╮"
  particleos_draw_char "$((home_disk_x-1))" "$((home_disk_y+home_disk_height))" "$PS_MAGENTA" "╰"
  particleos_draw_char "$((home_disk_x+home_disk_width))" "$((home_disk_y+home_disk_height))" "$PS_MAGENTA" "╯"
  particleos_animated_text "$((home_disk_x + 5))" "$((home_disk_y - 2))" "$PS_MAGENTA" "systemd-homed (encrypted)" 0.02
  sleep 0.1

  local home_width=10
  local home_x=$((home_disk_x + (home_disk_width - home_width)/2))
  local home_y=$((home_disk_y + home_disk_height/2 - 1))
  particleos_reveal_element "$home_x" "$home_y" $home_width $filesystem_height "$PS_MAGENTA" "solid" ""
  particleos_spawn_particles "$((home_x+home_width/2))" "$((home_y+1))" 3 10 "$PS_MAGENTA"
  particleos_animated_text "$((home_x+2))" "$((home_y+1))" "$PS_MAGENTA" "/home" 0.03
  sleep 0.5

  particleos_draw_box $border_x $border_y $border_width $border_height "$PS_WHITE" "dashed" ""
  sleep 0.1
  particleos_animated_text "$security_x" "$security_y" "$PS_WHITE" "Secure Boot - Verity - TPM2 - LUKS" 0.02
  sleep 0.2

  particleos_clear_area "$tpm_x" "$tpm_y" "$tpm_width" "$tpm_height"
  particleos_reveal_element "$tpm_x" "$tpm_y" $tpm_width $tpm_height "$PS_WHITE" "solid" ""
  particleos_animated_text "$((tpm_x+5))" "$((tpm_y+1))" "$PS_WHITE" "TPM2 Unlock" 0.04

  particleos_position "$tpm_x" "$tpm_y"
  printf "${PS_WHITE}╭"
  for ((i=1; i<tpm_width-1; i++)); do
    printf "─"
  done
  printf "╮${PS_RESET}"
  sleep 0.5

  particleos_reveal_element "$sysupdate_x" "$sysupdate_y" $sysupdate_width $sysupdate_height "$PS_CYAN" "dashed" ""
  particleos_animated_text "$((sysupdate_x+6))" "$((sysupdate_y+1))" "$PS_CYAN" "systemd-sysupdate" 0.02
  particleos_animated_text "$((sysupdate_x+6))" "$((sysupdate_y+3))" "$PS_CYAN" "A/B Image Updates" 0.02

  for ((i=0; i<$((disk_box_y - (sysupdate_y + sysupdate_height))); i++)); do
    particleos_draw_char "$((sysupdate_x + sysupdate_width/2))" "$((sysupdate_y + sysupdate_height + i))" "$PS_CYAN" "•"
    sleep 0.01
  done

  for ((i=0; i<$((sysupdate_y - (usr_area_y + usr_area_height))); i++)); do
    particleos_draw_char "$((sysupdate_x + sysupdate_width/2))" "$((sysupdate_y - 1 - i))" "$PS_CYAN" "•"
    sleep 0.01
  done

  particleos_position 1 "$LINES"
  
  while true; do
    sleep 0.5
    
    current_time=$(date +%s)
    spinner_chars=("-" "|" "/" "-")
    char_index=$((current_time % 4))
    animation_char=${spinner_chars[$char_index]}
    
    bottom_right_x=$((COLUMNS - 2))
    bottom_right_y=$((LINES - 1))
    particleos_position "$bottom_right_x" "$bottom_right_y"
    printf "${PS_WHITE}${animation_char}${PS_RESET}"
    
    particleos_position 1 "$LINES"
  done
  return 0
}
particleos_run() {
  particleos_store_terminal_state
  
  (
    exec 0</dev/null
    
    exec >/dev/tty 2>/dev/null
    
    trap 'particleos_show_cursor; particleos_reset_colors; exit 0' TERM INT
    
    particleos_visualize_modified() {
      read() {
        return 0
      }
      
      particleos_visualize
    }
    
    particleos_visualize_modified
  ) &
  
  VIZ_PID=$!
  
  read -n 1 -s
  
  kill -TERM $VIZ_PID 2>/dev/null
  
  sleep 0.2
  
  if kill -0 $VIZ_PID 2>/dev/null; then
    kill -9 $VIZ_PID 2>/dev/null
  fi
  
  particleos_show_cursor
  particleos_reset_colors
  stty sane 2>/dev/null
  
  printf "\033[?25h"
  
  return 0
}
particleos_run