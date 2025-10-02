#!/bin/bash

# Spotify Episode Update Script - Modular Version
# This script reads a CSV file and updates episode metadata on Spotify
# CSV Format: url;field1;field2;... where fields match Spotify API field names

# Load configuration from .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "\033[0;31mError: .env file not found at $ENV_FILE\033[0m"
    echo -e "\033[1;33mPlease copy env.example to .env and configure it:\033[0m"
    echo -e "\033[0;34m  cp env.example .env\033[0m"
    echo -e "\033[0;34m  nano .env\033[0m"
    exit 1
fi

# Source the .env file
set -a
source "$ENV_FILE"
set +a

# Validate required variables
if [[ -z "$COOKIE_STRING" || "$COOKIE_STRING" == "your_cookie_string_here" ]]; then
    echo -e "\033[0;31mError: COOKIE_STRING not configured in .env file\033[0m"
    exit 1
fi

if [[ -z "$SHOW_ID" ]]; then
    echo -e "\033[0;31mError: SHOW_ID not configured in .env file\033[0m"
    exit 1
fi

# Set defaults for optional variables
CSV_FILE="${CSV_FILE:-spotify.csv}"
LOG_FILE="${LOG_FILE:-output.log}"
CSV_DELIMITER="${CSV_DELIMITER:-;}"

# Valid Spotify API fields for episode updates
VALID_FIELDS=(
    "title"
    "publishOn"
    "description"
    "seasonNumber"
    "episodeNumber"
    "episodeType"
    "isPublished"
    "podcastEpisodeIsExplicit"
    "isDraft"
)

# Global arrays to store CSV structure
declare -a CSV_HEADERS
declare -a UPDATE_FIELDS

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to log messages to both console and log file
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Print to console with colors (to stderr so it doesn't interfere with function output)
    echo -e "$message" >&2
    
    # Strip colors and write to log file
    local clean_message=$(echo "$message" | sed 's/\\033\[[0-9;]*m//g')
    echo "[$timestamp] $clean_message" >> "$LOG_FILE"
}

# Function to log only to file (for detailed logs)
log_file_only() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local clean_message=$(echo "$message" | sed 's/\\033\[[0-9;]*m//g')
    echo "[$timestamp] $clean_message" >> "$LOG_FILE"
}

# Function to validate if field is a valid Spotify API field
is_valid_field() {
    local field="$1"
    for valid_field in "${VALID_FIELDS[@]}"; do
        if [[ "$field" == "$valid_field" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to validate field value
validate_field_value() {
    local field="$1"
    local value="$2"
    
    case "$field" in
        "podcastEpisodeIsExplicit"|"isPublished"|"isDraft")
            if [[ "$value" != "true" && "$value" != "false" ]]; then
                log_message "${RED}Error: Field '$field' must be 'true' or 'false', got '$value'${NC}"
                return 1
            fi
            ;;
        "episodeType")
            if [[ "$value" != "full" && "$value" != "trailer" && "$value" != "bonus" ]]; then
                log_message "${RED}Error: Field '$field' must be 'full', 'trailer', or 'bonus', got '$value'${NC}"
                return 1
            fi
            ;;
        "seasonNumber")
            if [[ "$value" != "null" ]] && ! [[ "$value" =~ ^[0-9]+$ ]]; then
                log_message "${RED}Error: Field '$field' must be a number or 'null', got '$value'${NC}"
                return 1
            fi
            ;;
        "episodeNumber")
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                log_message "${RED}Error: Field '$field' must be a number, got '$value'${NC}"
                return 1
            fi
            ;;
        "publishOn")
            if ! [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]; then
                log_message "${RED}Error: Field '$field' must be in YYYY-MM-DDTHH:MM:SS.000Z format, got '$value'${NC}"
                return 1
            fi
            ;;
        "description"|"title")
            if [[ -z "$value" ]]; then
                log_message "${RED}Error: Field '$field' cannot be empty${NC}"
                return 1
            fi
            ;;
    esac
    
    return 0
}

# Function to parse and validate CSV headers
parse_and_validate_headers() {
    # Read first line of CSV to get headers
    local header_line=$(head -n 1 "$CSV_FILE")
    
    # Strip carriage returns (for Windows line endings compatibility)
    header_line="${header_line//$'\r'/}"
    
    # Parse headers using the delimiter
    IFS="$CSV_DELIMITER" read -ra CSV_HEADERS <<< "$header_line"
    
    # Strip any remaining carriage returns from each header field
    for i in "${!CSV_HEADERS[@]}"; do
        CSV_HEADERS[$i]="${CSV_HEADERS[$i]//$'\r'/}"
    done
    
    # First column must be 'url'
    if [[ "${CSV_HEADERS[0]}" != "url" ]]; then
        log_message "${RED}Error: First column must be 'url', found '${CSV_HEADERS[0]}'${NC}"
        return 1
    fi
    
    # Validate remaining headers
    for i in "${!CSV_HEADERS[@]}"; do
        if [[ $i -eq 0 ]]; then
            continue  # Skip 'url' column
        fi
        
        local field="${CSV_HEADERS[$i]}"
        if ! is_valid_field "$field"; then
            log_message "${RED}Error: Invalid field '$field' in CSV header${NC}"
            log_message "${YELLOW}Valid fields are: ${VALID_FIELDS[*]}${NC}"
            return 1
        fi
        UPDATE_FIELDS+=("$field")
    done
    
    log_message "${GREEN}CSV validation passed${NC}"
    log_message "${BLUE}Update fields: ${UPDATE_FIELDS[*]}${NC}"
    return 0
}

# Function to extract episode ID from URL
extract_episode_id() {
    local url="$1"
    
    # Handle case where URL is just an episode ID
    if [[ ! "$url" =~ https:// ]]; then
        echo "$url"
        return
    fi
    
    # Extract episode ID from full URL
    if [[ "$url" =~ /episode/([^/?]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

# Function to get episode data from Spotify API
get_episode_data() {
    local episode_id="$1"
    
    if [[ -z "$episode_id" ]]; then
        echo ""
        return 1
    fi
    
    local response=$(curl -s -w "\n%{http_code}" "https://creators.spotify.com/pod/api/proxy/v3/episodes/spotify:episode:$episode_id/overview" \
        -b "$COOKIE_STRING")
    
    local http_code="${response##*$'\n'}"
    local response_body="${response%$'\n'*}"
    
    if [[ $? -ne 0 ]]; then
        log_message "${RED}Error: Failed to get episode data (curl error)${NC}"
        return 1
    fi
    
    log_file_only "GET /overview HTTP Status: $http_code"
    
    if [[ "$http_code" != "200" ]]; then
        log_message "${RED}Error: HTTP $http_code for episode $episode_id${NC}"
        return 1
    fi
    
    if ! echo "$response_body" | jq empty 2>/dev/null; then
        log_message "${RED}Error: Invalid JSON response${NC}"
        return 1
    fi
    
    # Debug: log the structure to help troubleshoot
    if [[ "${DEBUG:-0}" == "1" ]]; then
        log_message "${YELLOW}Debug: API Response structure:${NC}"
        echo "$response_body" | jq '.' | head -20 >> "$LOG_FILE"
    fi
    
    # Return the JSON response
    echo "$response_body"
    return 0
}

# Function to build JSON payload from field map
build_json_payload() {
    local fields_str="$1"
    local values_str="$2"
    shift 2
    local current_episode_data="$1"
    
    # Convert strings back to arrays (bash 3.2 compatible)
    IFS='|' read -ra update_fields_array <<< "$fields_str"
    IFS='|' read -ra update_values_array <<< "$values_str"
    
    # Dummy line to replace the old nameref line
    
    local json="{"
    local has_publish_on=0
    
    # ONLY include fields from CSV (Spotify API preserves other fields automatically)
    for i in "${!update_fields_array[@]}"; do
        local field="${update_fields_array[$i]}"
        local value="${update_values_array[$i]}"
        
        if [[ "$field" == "publishOn" ]]; then
            has_publish_on=1
        fi
        
        # Handle numeric vs string fields
        if [[ "$field" == "episodeNumber" ]] || [[ "$field" == "seasonNumber" ]]; then
            # Numeric fields - no quotes (handle null for seasonNumber)
            json+="\"$field\":$value,"
        elif [[ "$field" == "isPublished" ]] || [[ "$field" == "podcastEpisodeIsExplicit" ]] || [[ "$field" == "isDraft" ]]; then
            # Boolean fields - no quotes
            json+="\"$field\":$value,"
        else
            # String fields (escape quotes)
            value="${value//\"/\\\"}"
            json+="\"$field\":\"$value\","
        fi
    done
    
    # Extract episode data object (might be nested)
    local episode_obj="$current_episode_data"
    if echo "$current_episode_data" | jq -e '.episode' >/dev/null 2>&1; then
        episode_obj=$(echo "$current_episode_data" | jq -r '.episode')
    elif echo "$current_episode_data" | jq -e '.data' >/dev/null 2>&1; then
        episode_obj=$(echo "$current_episode_data" | jq -r '.data')
    fi
    
    # CRITICAL: Ensure publishOn is ALWAYS present (required by Spotify API)
    # If not provided in CSV, fetch from current episode data
    if [[ $has_publish_on -eq 0 ]]; then
        # Try multiple possible field names for publish date
        local publish_on=$(echo "$episode_obj" | jq -r '.publishOn // .publishedAt // .releaseDate // .published // empty')
        
        if [[ -z "$publish_on" || "$publish_on" == "null" ]]; then
            log_message "${YELLOW}Debug: Episode data keys (first 20):${NC}"
            log_message "$(echo "$episode_obj" | jq -r 'keys[:20] | join(", ")' 2>/dev/null || echo 'Unable to parse keys')"
            log_message "${YELLOW}Debug: Raw data sample (first 300 chars):${NC}"
            log_message "${episode_obj:0:300}"
        fi
        
        if [[ -n "$publish_on" && "$publish_on" != "null" ]]; then
            log_file_only "Using current publishOn: $publish_on"
            json+="\"publishOn\":\"$publish_on\","
        else
            log_message "${RED}Error: No publishOn date available (not in CSV and not in episode data)${NC}"
            log_message "${YELLOW}Hint: Add a 'publishOn' column to your CSV with dates in format YYYY-MM-DDTHH:MM:SS.000Z${NC}"
            return 1
        fi
    fi
    
    # CRITICAL: Include wizardDraftedToPublishOn if present in episode data (required by API)
    local wizard_date=$(echo "$episode_obj" | jq -r '.wizardDraftedToPublishOn // empty')
    if [[ -n "$wizard_date" && "$wizard_date" != "null" ]]; then
        log_file_only "Including wizardDraftedToPublishOn: $wizard_date"
        json+="\"wizardDraftedToPublishOn\":\"$wizard_date\","
    fi
    
    # Remove trailing comma and close JSON
    json="${json%,}}"
    
    echo "$json"
    return 0
}

# Function to update episode with dynamic fields
update_episode() {
    local episode_id="$1"
    local fields_str="$2"
    local values_str="$3"
    local current_data="$4"
    
    if [[ -z "$episode_id" ]]; then
        log_message "${RED}Error: Missing episode ID${NC}"
        return 1
    fi
    
    # Build JSON payload (passing field/value strings)
    local json_data=$(build_json_payload "$fields_str" "$values_str" "$current_data")
    
    if [[ $? -ne 0 ]]; then
        log_message "${RED}Error: Failed to build JSON payload${NC}"
        return 1
    fi
    
    log_file_only "Update Payload: ${json_data:0:200}..."
    
    local response=$(curl -s -w "\n%{http_code}" "https://creators.spotify.com/pod/api/proxy/v3/episodes/spotify:episode:$episode_id/update?isMumsCompatible=true" \
        -H 'content-type: application/json' \
        -b "$COOKIE_STRING" \
        --data-raw "$json_data")
    
    local http_code="${response##*$'\n'}"
    local response_body="${response%$'\n'*}"
    
    log_file_only "POST /update HTTP Status: $http_code"
    
    if [[ "$http_code" == "200" ]]; then
        log_message ""
        log_message "${GREEN}✓ Episode updated successfully${NC}"
        return 0
    else
        log_message "${RED}✗ Failed to update episode (HTTP $http_code)${NC}"
        if [[ -n "$response_body" ]]; then
            log_file_only "Error Response: $response_body"
            log_message "${RED}Response: ${response_body:0:100}${NC}"
        fi
        return 1
    fi
}

# Function to verify episode update - only show fields that were updated
verify_episode_update() {
    local episode_id="$1"
    local fields_str="$2"
    
    # Wait 1 second before verification
    sleep 1
    
    local episode_data=$(get_episode_data "$episode_id")
    if [[ $? -ne 0 ]]; then
        log_message "${RED}Verification failed: Could not retrieve episode data${NC}"
        return 1
    fi
    
    log_file_only "Verification data retrieved successfully"
    
    # Convert fields string to array
    IFS='|' read -ra fields_array <<< "$fields_str"
    
    log_message ""
    log_message "${GREEN}Verification:${NC}"
    
    # Show only fields that were updated
    for field in "${fields_array[@]}"; do
        local value=""
        case "$field" in
            "episodeNumber")
                value=$(echo "$episode_data" | jq -r '.podcastEpisodeNumber // .episodeNumber // "N/A"')
                log_message "${BLUE}- Episode Number: $value${NC}"
                ;;
            "seasonNumber")
                value=$(echo "$episode_data" | jq -r '.podcastSeasonNumber // .seasonNumber // "N/A"')
                log_message "${BLUE}- Season Number: $value${NC}"
                ;;
            "episodeType")
                value=$(echo "$episode_data" | jq -r '.podcastEpisodeType // .episodeType // "N/A"')
                log_message "${BLUE}- Episode Type: $value${NC}"
                ;;
            "title")
                value=$(echo "$episode_data" | jq -r '.title // "N/A"')
                log_message "${BLUE}- Title: $value${NC}"
                ;;
            "description")
                value=$(echo "$episode_data" | jq -r '.description // "N/A"')
                log_message "${BLUE}- Description: ${value:0:100}...${NC}"
                ;;
            "publishOn")
                value=$(echo "$episode_data" | jq -r '.publishOn // "N/A"')
                log_message "${BLUE}- Publish Date: $value${NC}"
                ;;
            "podcastEpisodeIsExplicit")
                value=$(echo "$episode_data" | jq -r '.podcastEpisodeIsExplicit // "N/A"')
                log_message "${BLUE}- Is Explicit: $value${NC}"
                ;;
            "isPublished")
                value=$(echo "$episode_data" | jq -r '.isPublished // "N/A"')
                log_message "${BLUE}- Is Published: $value${NC}"
                ;;
            "isDraft")
                value=$(echo "$episode_data" | jq -r '.isDraft // "N/A"')
                log_message "${BLUE}- Is Draft: $value${NC}"
                ;;
        esac
    done
    
    return 0
}

# Function to add random delay
add_delay() {
    local delay=$((0 + RANDOM % 4))
    log_message "${YELLOW}Waiting $delay seconds...${NC}"
    sleep $delay
}

# Main processing function
process_episodes() {
    local line_number=0
    local success_count=0
    local error_count=0
    
    log_message "${GREEN}Starting episode updates...${NC}"
    log_message "${BLUE}Processing CSV file: $CSV_FILE${NC}"
    log_message ""
    
    # Read CSV line by line (handle files without trailing newline)
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        
        # Skip header row
        if [[ $line_number -eq 1 ]]; then
            continue
        fi
        
        # Strip carriage returns (for Windows line endings compatibility)
        line="${line//$'\r'/}"
        
        # Skip empty lines
        if [[ -z "$line" ]]; then
            continue
        fi
        
        # Parse CSV values into array
        IFS="$CSV_DELIMITER" read -ra values <<< "$line"
        
        # Strip carriage returns from each value
        for i in "${!values[@]}"; do
            values[$i]="${values[$i]//$'\r'/}"
        done
        
        # First value is always URL
        local url="${values[0]}"
        
        if [[ -z "$url" ]]; then
            log_message "${YELLOW}Skipping line $line_number: No URL${NC}"
            continue
        fi
        
        # Extract episode ID
        local episode_id=$(extract_episode_id "$url")
        
        if [[ -z "$episode_id" ]]; then
            log_message "${RED}✗ Error: Invalid URL format: $url${NC}"
            log_message "${RED}Stopping script${NC}"
            error_count=$((error_count + 1))
            break
        fi
        
        log_message "${BLUE}Episode ID: $episode_id${NC}"
        
        # Get current episode data
        local current_data=$(get_episode_data "$episode_id")
        if [[ $? -ne 0 ]]; then
            log_message "${RED}✗ Error: Failed to get episode data${NC}"
            log_message "${RED}Stopping script${NC}"
            error_count=$((error_count + 1))
            break
        fi
        
        # Show title
        local episode_title=$(echo "$current_data" | jq -r '.title // "N/A"')
        log_message "${BLUE}Title: $episode_title${NC}"
        
        # Debug: Show raw response length
        if [[ "${DEBUG:-0}" == "1" ]]; then
            log_file_only "Debug: Response length: ${#current_data} bytes"
            log_file_only "Debug: First 500 chars: ${current_data:0:500}"
        fi
        
        # Build update fields and values arrays (bash 3.2 compatible)
        local update_fields_list=()
        local update_values_list=()
        local validation_failed=0
        for i in "${!UPDATE_FIELDS[@]}"; do
            local field="${UPDATE_FIELDS[$i]}"
            local value="${values[$((i + 1))]}"  # +1 because first column is URL
            
            if [[ -n "$value" ]]; then
                # Validate field value
                if ! validate_field_value "$field" "$value"; then
                    validation_failed=1
                    break
                fi
                update_fields_list+=("$field")
                update_values_list+=("$value")
            fi
        done
        
        # Skip this episode if validation failed
        if [[ $validation_failed -eq 1 ]]; then
            log_message "${RED}✗ Validation failed for episode${NC}"
            log_message "${RED}Stopping script${NC}"
            error_count=$((error_count + 1))
            break
        fi
        
        # Convert arrays to pipe-delimited strings
        local fields_str=$(IFS='|'; echo "${update_fields_list[*]}")
        local values_str=$(IFS='|'; echo "${update_values_list[*]}")
        
        # Show current values for fields being updated
        log_message ""
        log_message "${YELLOW}Current Values:${NC}"
        for i in "${!update_fields_list[@]}"; do
            local field="${update_fields_list[$i]}"
            local current_value=""
            case "$field" in
                "episodeNumber")
                    current_value=$(echo "$current_data" | jq -r '.podcastEpisodeNumber // .episodeNumber // "N/A"')
                    log_message "${BLUE}- Episode Number: $current_value${NC}"
                    ;;
                "seasonNumber")
                    current_value=$(echo "$current_data" | jq -r '.podcastSeasonNumber // .seasonNumber // "N/A"')
                    log_message "${BLUE}- Season Number: $current_value${NC}"
                    ;;
                "episodeType")
                    current_value=$(echo "$current_data" | jq -r '.podcastEpisodeType // .episodeType // "N/A"')
                    log_message "${BLUE}- Episode Type: $current_value${NC}"
                    ;;
                "title")
                    current_value=$(echo "$current_data" | jq -r '.title // "N/A"')
                    log_message "${BLUE}- Title: $current_value${NC}"
                    ;;
                "description")
                    current_value=$(echo "$current_data" | jq -r '.description // "N/A"')
                    log_message "${BLUE}- Description: ${current_value:0:100}...${NC}"
                    ;;
                "publishOn")
                    current_value=$(echo "$current_data" | jq -r '.publishOn // "N/A"')
                    log_message "${BLUE}- Publish Date: $current_value${NC}"
                    ;;
                "podcastEpisodeIsExplicit")
                    current_value=$(echo "$current_data" | jq -r '.podcastEpisodeIsExplicit // "N/A"')
                    log_message "${BLUE}- Is Explicit: $current_value${NC}"
                    ;;
                "isPublished")
                    current_value=$(echo "$current_data" | jq -r '.isPublished // "N/A"')
                    log_message "${BLUE}- Is Published: $current_value${NC}"
                    ;;
                "isDraft")
                    current_value=$(echo "$current_data" | jq -r '.isDraft // "N/A"')
                    log_message "${BLUE}- Is Draft: $current_value${NC}"
                    ;;
            esac
        done
        
        # Update episode
        if update_episode "$episode_id" "$fields_str" "$values_str" "$current_data"; then
            # Verify the update
            if verify_episode_update "$episode_id" "$fields_str"; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
                log_message "${RED}Stopping script${NC}"
                break
            fi
        else
            error_count=$((error_count + 1))
            log_message "${RED}Stopping script${NC}"
            break
        fi
        
        log_message ""
        
        # Add delay between requests
        if [[ $line_number -lt $(wc -l < "$CSV_FILE") ]]; then
            add_delay
            log_message ""
        fi
        
        # Clear the associative array for next iteration
        unset update_fields
        
    done < "$CSV_FILE"
    
    log_message "${GREEN}Processing complete!${NC}"
    log_message "${GREEN}Successfully updated: $success_count episodes${NC}"
    log_message "${RED}Errors: $error_count episodes${NC}"
}

# Check if required tools are available
check_dependencies() {
    local missing_deps=()
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_message "${RED}Error: Missing required dependencies: ${missing_deps[*]}${NC}"
        log_message "Please install the missing dependencies and try again."
        exit 1
    fi
}

# Check if CSV file exists
if [[ ! -f "$CSV_FILE" ]]; then
    log_message "${RED}Error: CSV file '$CSV_FILE' not found${NC}"
    exit 1
fi

# Main execution
log_message "${GREEN}Spotify Episode Update Script${NC}"
log_message "${BLUE}========================================${NC}"
log_message ""

check_dependencies

# Parse and validate CSV headers
if ! parse_and_validate_headers; then
    log_message "${RED}CSV validation failed. Stopping script.${NC}"
    exit 1
fi

log_message ""
process_episodes
