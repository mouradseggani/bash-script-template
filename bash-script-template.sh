#!/bin/bash

#===============================================================================
# MariaDB Backup Script with Mariabackup
# Author: Mourad SEGGANI
# Version: 1.0
# Description: Comprehensive backup solution for MariaDB with multiple modes
#===============================================================================

set -euo pipefail

#===============================================================================
# GLOBAL VARIABLES
#===============================================================================

declare SCRIPT_NAME
declare SCRIPT_DIR
declare SCRIPT_PID
declare TIMESTAMP
declare LOG_DIR
declare LOG_FILE
declare VERBOSE_MODE
declare INTERACTIVE_MODE
declare LOCK_FILE
declare LOCK_FD

SCRIPT_NAME="$(basename "${0}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PID="$"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

# Logging configuration
LOG_DIR="/var/log/mariadb-backup"
LOG_FILE="${LOG_DIR}/mariadb-backup_${TIMESTAMP}.log"
VERBOSE_MODE=false

# Lock configuration
LOCK_FILE="/var/run/mariadb-backup.lock"
LOCK_FD=200

# Detect execution context (interactive vs cron/daemon)
INTERACTIVE_MODE=false
if [[ -t 0 ]] && [[ -t 1 ]] && [[ -t 2 ]]; then
    INTERACTIVE_MODE=true
fi

# Color codes for interactive terminal output
declare -r COLOR_RED='\033[0;31m'
declare -r COLOR_GREEN='\033[0;32m'
declare -r COLOR_YELLOW='\033[1;33m'
declare -r COLOR_BLUE='\033[0;34m'
declare -r COLOR_RESET='\033[0m'

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

#-------------------------------------------------------------------------------
# Function: setup_logging
# Description: Initialize logging directory and file
# Arguments: None
# Returns: 0 on success, 1 on failure
#-------------------------------------------------------------------------------
setup_logging() {
    # Create log directory if it doesn't exist
    if [[ ! -d "${LOG_DIR}" ]]; then
        if ! mkdir -p "${LOG_DIR}" 2>/dev/null; then
            printf "ERROR: Cannot create log directory: %s\n" "${LOG_DIR}" >&2
            return 1
        fi
    fi
    
    # Test write permissions
    if ! touch "${LOG_FILE}" 2>/dev/null; then
        printf "ERROR: Cannot write to log file: %s\n" "${LOG_FILE}" >&2
        return 1
    fi
    
    return 0
}

#===============================================================================
# LOCK MANAGEMENT FUNCTIONS
#===============================================================================

#-------------------------------------------------------------------------------
# Function: acquire_lock
# Description: Acquire exclusive lock to prevent concurrent executions
# Arguments: None
# Returns: 0 on success, 1 on failure
#-------------------------------------------------------------------------------
acquire_lock() {
    local lock_dir
    
    # Create lock directory if it doesn't exist
    lock_dir="$(dirname "${LOCK_FILE}")"
    if [[ ! -d "${lock_dir}" ]]; then
        if ! mkdir -p "${lock_dir}" 2>/dev/null; then
            log_error "Cannot create lock directory: ${lock_dir}"
            return 1
        fi
    fi
    
    # Open lock file
    if ! exec {LOCK_FD}>"${LOCK_FILE}"; then
        log_error "Cannot open lock file: ${LOCK_FILE}"
        return 1
    fi
    
    # Try to acquire exclusive lock (non-blocking)
    if ! flock -n "${LOCK_FD}"; then
        log_error "Another instance is already running"
        check_running_instance
        exec {LOCK_FD}>&-
        return 1
    fi
    
    # Write current PID to lock file
    printf "%s\n" "${SCRIPT_PID}" >&"${LOCK_FD}"
    
    log_verbose "Exclusive lock acquired"
    return 0
}

#-------------------------------------------------------------------------------
# Function: check_running_instance
# Description: Check and report details about running instance
# Arguments: None
# Returns: None
#-------------------------------------------------------------------------------
check_running_instance() {
    local running_pid
    
    log_verbose "Lock file: ${LOCK_FILE}"
    
    if [[ ! -r "${LOCK_FILE}" ]]; then
        return 0
    fi
    
    running_pid="$(head -1 "${LOCK_FILE}" 2>/dev/null | tr -d '[:space:]')"
    
    if [[ -z "${running_pid}" ]] || [[ ! "${running_pid}" =~ ^[0-9]+$ ]]; then
        log_verbose "Invalid PID in lock file"
        return 0
    fi
    
    log_verbose "Lock file PID: ${running_pid}"
    
    if kill -0 "${running_pid}" 2>/dev/null; then
        log_verbose "Process ${running_pid} is active"
    else
        log_warn "Stale lock detected - process ${running_pid} not running"
    fi
}

#-------------------------------------------------------------------------------
# Function: release_lock
# Description: Release the exclusive lock and cleanup
# Arguments: None
# Returns: None
#-------------------------------------------------------------------------------
release_lock() {
    if [[ -n "${LOCK_FD}" ]] && [[ "${LOCK_FD}" =~ ^[0-9]+$ ]]; then
        flock -u "${LOCK_FD}" 2>/dev/null || true
        exec {LOCK_FD}>&- 2>/dev/null || true
        log_verbose "Lock released"
    fi
    
    cleanup_lock_file
}

#-------------------------------------------------------------------------------
# Function: cleanup_lock_file
# Description: Remove lock file if it belongs to current process
# Arguments: None
# Returns: None
#-------------------------------------------------------------------------------
cleanup_lock_file() {
    local file_pid
    
    if [[ ! -f "${LOCK_FILE}" ]]; then
        return 0
    fi
    
    file_pid="$(head -1 "${LOCK_FILE}" 2>/dev/null | tr -d '[:space:]')"
    
    if [[ "${file_pid}" == "${SCRIPT_PID}" ]]; then
        rm -f "${LOCK_FILE}" 2>/dev/null || true
        log_verbose "Lock file cleaned up"
    fi
}

#-------------------------------------------------------------------------------
# Function: setup_exit_trap
# Description: Setup signal handlers for clean exit
# Arguments: None
# Returns: None
#-------------------------------------------------------------------------------
setup_exit_trap() {
    trap 'release_lock; log_info "Script terminated"' EXIT INT TERM
    log_verbose "Exit handlers configured"
}



#===============================================================================
# LOGGING FUNCTIONS
#===============================================================================

#-------------------------------------------------------------------------------
# Function: log_message
# Description: Main logging function with context detection
# Arguments: $1 = level, $2 = message, $3 = color, $4 = verbose_only (optional)
# Returns: None
#-------------------------------------------------------------------------------
log_message() {
    local level="${1}"
    local message="${2}"
    local color="${3}"
    local verbose_only="${4:-false}"
    local timestamp
    
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Skip if verbose-only message and verbose mode is disabled
    if [[ "${verbose_only}" == true ]] && [[ "${VERBOSE_MODE}" == false ]]; then
        return 0
    fi
    
    # Always write to log file (no colors)
    printf "[%s] [%s] [%s] %s\n" "${timestamp}" "${SCRIPT_PID}" "${level}" "${message}" >> "${LOG_FILE}" 2>/dev/null || true
    
    # Terminal output only in interactive mode
    if [[ "${INTERACTIVE_MODE}" == true ]]; then
        printf "${color}[%s] [%s] %s${COLOR_RESET}\n" "${timestamp}" "${level}" "${message}"
    fi
}

#-------------------------------------------------------------------------------
# Function: log_error
# Description: Log error messages
# Arguments: $1 = error_message
# Returns: None
#-------------------------------------------------------------------------------
log_error() {
    log_message "ERROR" "${1}" "${COLOR_RED}"
}

#-------------------------------------------------------------------------------
# Function: log_warn
# Description: Log warning messages
# Arguments: $1 = warning_message
# Returns: None
#-------------------------------------------------------------------------------
log_warn() {
    log_message "WARN" "${1}" "${COLOR_YELLOW}"
}

#-------------------------------------------------------------------------------
# Function: log_info
# Description: Log informational messages
# Arguments: $1 = info_message
# Returns: None
#-------------------------------------------------------------------------------
log_info() {
    log_message "INFO" "${1}" "${COLOR_GREEN}"
}

#-------------------------------------------------------------------------------
# Function: log_verbose
# Description: Log verbose messages (more detailed information)
# Arguments: $1 = verbose_message
# Returns: None
#-------------------------------------------------------------------------------
log_verbose() {
    log_message "VERBOSE" "${1}" "${COLOR_BLUE}" true
}

#===============================================================================
# BANNER AND HELP FUNCTIONS
#===============================================================================

#-------------------------------------------------------------------------------
# Function: show_banner
# Description: Display script banner
# Arguments: None
# Returns: None
#-------------------------------------------------------------------------------
show_banner() {
    if [[ "${INTERACTIVE_MODE}" == true ]]; then
        printf "================================================================================\n"
        printf " MariaDB Backup Script with Mariabackup v1.0\n"
        printf " PID: %s | Log: %s\n" "${SCRIPT_PID}" "${LOG_FILE}"
        printf " Mode: %s | Verbose: %s\n" \
            "$(if [[ "${INTERACTIVE_MODE}" == true ]]; then printf "Interactive"; else printf "Non-interactive"; fi)" \
            "$(if [[ "${VERBOSE_MODE}" == true ]]; then printf "Enabled"; else printf "Disabled"; fi)"
        printf "================================================================================\n"
    fi
    
    if [[ "${VERBOSE_MODE}" == true ]]; then
        log_verbose "Script started - PID: ${SCRIPT_PID}, Mode: $(if [[ "${INTERACTIVE_MODE}" == true ]]; then printf "Interactive"; else printf "Non-interactive"; fi)"
    else
        log_info "Script started - PID: ${SCRIPT_PID}"
    fi
}

#-------------------------------------------------------------------------------
# Function: show_usage
# Description: Display script usage information
# Arguments: None
# Returns: None
#-------------------------------------------------------------------------------
show_usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
    -h, --help          Show this help message
    -v, --verbose       Enable verbose mode (more detailed output)
    -l, --log-dir DIR   Set log directory (default: ${LOG_DIR})
    --lock-file FILE    Set lock file path (default: ${LOCK_FILE})

EXECUTION MODES:
    Interactive:        ./script.sh (colors, terminal output)
    Non-interactive:    cron, systemd, etc. (logs only, no colors)

EXAMPLES:
    ${SCRIPT_NAME} --verbose
    ${SCRIPT_NAME} --log-dir /custom/log/path
    ${SCRIPT_NAME} --lock-file /tmp/custom-backup.lock

EOF
}

#===============================================================================
# INITIALIZATION FUNCTIONS
#===============================================================================

#-------------------------------------------------------------------------------
# Function: parse_arguments
# Description: Parse command line arguments
# Arguments: $@ = script_arguments
# Returns: 0 on success, 1 on failure
#-------------------------------------------------------------------------------
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE_MODE=true
                log_verbose "Verbose mode enabled - will provide detailed information"
                ;;
            -l|--log-dir)
                if [[ -n "${2:-}" ]]; then
                    LOG_DIR="${2}"
                    LOG_FILE="${LOG_DIR}/mariadb-backup_${TIMESTAMP}.log"
                    log_verbose "Custom log directory set: ${LOG_DIR}"
                    shift
                else
                    log_error "Option --log-dir requires a directory path"
                    return 1
                fi
                ;;
            --lock-file)
                if [[ -n "${2:-}" ]]; then
                    LOCK_FILE="${2}"
                    log_verbose "Custom lock file set: ${LOCK_FILE}"
                    shift
                else
                    log_error "Option --lock-file requires a file path"
                    return 1
                fi
                ;;
            *)                log_error "Unknown option: ${1}"
                show_usage
                return 1
                ;;
        esac
        shift
    done
    
    return 0
}

#-------------------------------------------------------------------------------
# Function: initialize_script
# Description: Initialize script environment
# Arguments: None
# Returns: 0 on success, 1 on failure
#-------------------------------------------------------------------------------
initialize_script() {
    # Setup logging
    if ! setup_logging; then
        printf "FATAL: Failed to initialize logging\n" >&2
        return 1
    fi
    
    # Setup exit trap for cleanup
    setup_exit_trap
    
    # Acquire exclusive lock
    if ! acquire_lock; then
        return 1
    fi
    
    # Show banner
    show_banner
    
    # Log initialization details in verbose mode
    if [[ "${VERBOSE_MODE}" == true ]]; then
        log_verbose "Script directory: ${SCRIPT_DIR}"
        log_verbose "Log file: ${LOG_FILE}"
        log_verbose "Lock file: ${LOCK_FILE}"
        log_verbose "Interactive mode: ${INTERACTIVE_MODE}"
        log_verbose "Terminal detection: stdin=$(if [[ -t 0 ]]; then printf "TTY"; else printf "pipe"; fi), stdout=$(if [[ -t 1 ]]; then printf "TTY"; else printf "pipe"; fi), stderr=$(if [[ -t 2 ]]; then printf "TTY"; else printf "pipe"; fi)"
        log_verbose "Parent process: $(ps -o comm= -p $PPID 2>/dev/null || printf "unknown")"
        log_verbose "Environment: USER=${USER:-unknown}, TERM=${TERM:-unknown}"
    fi
    
    return 0
}

#===============================================================================
# MAIN FUNCTION
#===============================================================================

#-------------------------------------------------------------------------------
# Function: main
# Description: Main script entry point
# Arguments: $@ = script_arguments
# Returns: Exit code
#-------------------------------------------------------------------------------
main() {
    # Parse arguments
    if ! parse_arguments "$@"; then
        exit 1
    fi
    
    # Initialize script
    if ! initialize_script; then
        exit 1
    fi
    
    # Log initialization completion
    log_info "Initialization completed successfully"
    log_verbose "Ready to proceed with MariaDB backup operations"
    
    return 0
}

# Execute main if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi