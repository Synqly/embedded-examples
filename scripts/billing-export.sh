#!/bin/bash
set -euo pipefail

# Display usage information
show_usage() {
	cat <<EOF
Usage: billing-export.sh [OPTIONS]

Export billing data from a Synqly instance for specified time periods.

Required Arguments:
  --url URL           Synqly instance URL
  --user USER         Admin username

Root Token (one required, precedence order):
  --token TOKEN            Root token (appears in shell history)
  SYNQLY_TOKEN env var     Set token via environment variable
  --token-file FILE        Path to file containing token
  Interactive prompt       Prompted if TTY detected and no token provided

Password (one required, precedence order):
  --password PASS          Password (appears in shell history)
  SYNQLY_PASSWORD env var  Set password via environment variable
  --password-file FILE     Path to file containing password
  stdin pipe               Echo password | script (for vault integration)
  Interactive prompt       Prompted if TTY detected and no password provided

Time Period (default: previous month):
  --month MONTH       Export single month (YYYY-MM or name like 'january')
  OR
  --from MONTH        Start month for range (YYYY-MM or name)
  --to MONTH          End month for range (YYYY-MM or name)

  Note: Month names are case-insensitive. If month > current month, assumes previous year.
        Example: In January 2026, '--month march' resolves to March 2025.

Optional Arguments:
  --output DIR        Output directory (default: current directory)
  --insecure          Skip SSL certificate verification

Examples:
  # Export with token and password from files
  ./billing-export.sh --url https://synqly.example.com --token-file ~/.synqly-token --user admin --password-file ~/.synqly-pass --month 2026-01

  # Export with environment variables
  SYNQLY_TOKEN=<root-token> SYNQLY_PASSWORD=secret ./billing-export.sh --url https://synqly.example.com --user admin --from 2025-12 --to 2026-02

  # Export with password from stdin pipe (e.g., from vault)
  echo "secret" | ./billing-export.sh --url https://synqly.example.com --token-file ~/.synqly-token --user admin --month 2026-01

  # Export with interactive prompts for token and password
  ./billing-export.sh --url https://synqly.example.com --user admin --month 2026-01

EOF
	exit 0
}

# Check dependencies
check_dependencies() {
	local missing=()
	for cmd in curl jq tar gzip; do
		if ! command -v "$cmd" &>/dev/null; then
			missing+=("$cmd")
		fi
	done

	if [[ ${#missing[@]} -gt 0 ]]; then
		echo "Error: Required dependencies not found: ${missing[*]}" >&2
		echo "Please install missing dependencies and try again." >&2
		exit 1
	fi
}

# Resolve token from multiple sources in precedence order
resolve_token() {
	# 1. --token flag (already in TOKEN variable)
	if [[ -n "${TOKEN:-}" ]]; then
		return
	fi

	# 2. Environment variable
	if [[ -n "${SYNQLY_TOKEN:-}" ]]; then
		TOKEN="$SYNQLY_TOKEN"
		return
	fi

	# 3. Token file
	if [[ -n "${TOKEN_FILE:-}" ]]; then
		if [[ ! -f "$TOKEN_FILE" ]]; then
			echo "Error: Token file not found: $TOKEN_FILE" >&2
			exit 1
		fi
		TOKEN=$(head -n1 "$TOKEN_FILE")
		return
	fi

	# 4. Interactive prompt (TTY detected)
	if [[ -t 0 ]]; then
		read -rsp "Root Token: " TOKEN
		echo >&2
		return
	fi

	echo "Error: No token provided" >&2
	exit 1
}

# Resolve password from multiple sources in precedence order
resolve_password() {
	# 1. --password flag (already in PASSWORD variable)
	if [[ -n "${PASSWORD:-}" ]]; then
		return
	fi

	# 2. Environment variable
	if [[ -n "${SYNQLY_PASSWORD:-}" ]]; then
		PASSWORD="$SYNQLY_PASSWORD"
		return
	fi

	# 3. Password file
	if [[ -n "${PASSWORD_FILE:-}" ]]; then
		if [[ ! -f "$PASSWORD_FILE" ]]; then
			echo "Error: Password file not found: $PASSWORD_FILE" >&2
			exit 1
		fi
		PASSWORD=$(head -n1 "$PASSWORD_FILE")
		return
	fi

	# 4. Piped stdin (not a TTY)
	if [[ ! -t 0 ]]; then
		read -r PASSWORD
		return
	fi

	# 5. Interactive prompt (TTY detected)
	if [[ -t 0 ]]; then
		read -rsp "Password: " PASSWORD
		echo >&2
		return
	fi

	echo "Error: No password provided" >&2
	exit 1
}

# Get Synqly version (unauthenticated)
get_synqly_version() {
	local response
	response=$(curl -s $INSECURE "${URL}/v1/version")
	if [[ $? -ne 0 ]]; then
		echo "Error: Failed to connect to ${URL}" >&2
		exit 1
	fi
	echo "$response" | jq -r '.version // "unknown"'
}

# Authenticate and get access token
authenticate() {
	local response
	response=$(curl -s $INSECURE -X POST \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer ${TOKEN}" \
		-d "{\"name\": \"${USER}\", \"secret\": \"${PASSWORD}\"}" \
		"${URL}/v1/auth/logon/synqly-backoffice")

	if [[ $? -ne 0 ]]; then
		echo "Error: Network error during authentication" >&2
		exit 1
	fi

	# Check for API-level errors (4xx/5xx responses with .message)
	local api_error=$(echo "$response" | jq -r '.message // empty')
	if [[ -n "$api_error" ]]; then
		echo "Authentication failed: $api_error" >&2
		exit 1
	fi

	# Check auth_code for authentication result
	local auth_code=$(echo "$response" | jq -r '.result.auth_code // empty')
	if [[ "$auth_code" != "success" ]]; then
		local auth_msg=$(echo "$response" | jq -r '.result.auth_msg // "authentication failed"')
		echo "Authentication failed: $auth_msg (code: $auth_code)" >&2
		exit 1
	fi

	local token=$(echo "$response" | jq -r '.result.token.access.secret // empty')
	if [[ -z "$token" ]]; then
		echo "Authentication failed: no access token returned" >&2
		exit 1
	fi

	echo "$token"
}

# Cleanup function for temp directory
cleanup() {
	if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
		rm -rf "$TEMP_DIR"
	fi
}

# Log message to export.log with timestamp
log() {
	local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	echo "${timestamp} $1" | tee -a "$LOG_FILE" >&2
}

# Defaults
OUTPUT_DIR="."
INSECURE=""
MONTH=""
FROM_MONTH=""
TO_MONTH=""
PASSWORD=""
PASSWORD_FILE=""
TOKEN=""
TOKEN_FILE=""
URL=""
USER=""
TEMP_DIR=""
MONTHS_EXPORTED=()

# Parse arguments
while [[ $# -gt 0 ]]; do
	case $1 in
	--help | -h)
		show_usage
		;;
	--url)
		if [[ $# -lt 2 ]]; then
			echo "Error: --url requires a value" >&2
			exit 1
		fi
		URL="$2"
		shift 2
		;;
	--token)
		if [[ $# -lt 2 ]]; then
			echo "Error: --token requires a value" >&2
			exit 1
		fi
		TOKEN="$2"
		shift 2
		;;
	--token-file)
		if [[ $# -lt 2 ]]; then
			echo "Error: --token-file requires a value" >&2
			exit 1
		fi
		TOKEN_FILE="$2"
		shift 2
		;;
	--user)
		if [[ $# -lt 2 ]]; then
			echo "Error: --user requires a value" >&2
			exit 1
		fi
		USER="$2"
		shift 2
		;;
	--password)
		if [[ $# -lt 2 ]]; then
			echo "Error: --password requires a value" >&2
			exit 1
		fi
		PASSWORD="$2"
		shift 2
		;;
	--password-file)
		if [[ $# -lt 2 ]]; then
			echo "Error: --password-file requires a value" >&2
			exit 1
		fi
		PASSWORD_FILE="$2"
		shift 2
		;;
	--month)
		if [[ $# -lt 2 ]]; then
			echo "Error: --month requires a value" >&2
			exit 1
		fi
		MONTH="$2"
		shift 2
		;;
	--from)
		if [[ $# -lt 2 ]]; then
			echo "Error: --from requires a value" >&2
			exit 1
		fi
		FROM_MONTH="$2"
		shift 2
		;;
	--to)
		if [[ $# -lt 2 ]]; then
			echo "Error: --to requires a value" >&2
			exit 1
		fi
		TO_MONTH="$2"
		shift 2
		;;
	--output)
		if [[ $# -lt 2 ]]; then
			echo "Error: --output requires a value" >&2
			exit 1
		fi
		OUTPUT_DIR="$2"
		shift 2
		;;
	--insecure)
		INSECURE="-k"
		shift
		;;
	*)
		echo "Error: Unknown option: $1" >&2
		echo "Use --help for usage information" >&2
		exit 1
		;;
	esac
done

# Check dependencies first
check_dependencies

# Show usage if no arguments
if [[ -z "$URL" ]] && [[ -z "$USER" ]] && [[ -z "$MONTH" ]] && [[ -z "$FROM_MONTH" ]]; then
	show_usage
fi

# Validate required arguments
if [[ -z "$URL" ]]; then
	echo "Error: --url is required" >&2
	exit 1
fi

if [[ -z "$USER" ]]; then
	echo "Error: --user is required" >&2
	exit 1
fi

# Warn if insecure mode is enabled
if [[ -n "$INSECURE" ]]; then
	echo "WARNING: SSL certificate verification is disabled" >&2
fi

# Resolve token from multiple sources
resolve_token

# Resolve password from multiple sources
resolve_password

# Validate time period arguments
if [[ -n "$MONTH" ]] && [[ -n "$FROM_MONTH" ]]; then
	echo "Error: Cannot specify both --month and --from/--to" >&2
	exit 1
fi

if [[ -n "$MONTH" ]] && [[ -n "$TO_MONTH" ]]; then
	echo "Error: Cannot specify both --month and --from/--to" >&2
	exit 1
fi

# Note: Allowing no month specified - will default to previous month

if [[ -n "$FROM_MONTH" ]] && [[ -z "$TO_MONTH" ]]; then
	echo "Error: --from requires --to" >&2
	exit 1
fi

if [[ -n "$TO_MONTH" ]] && [[ -z "$FROM_MONTH" ]]; then
	echo "Error: --to requires --from" >&2
	exit 1
fi

# Convert month name to number (01-12)
month_to_number() {
	local month
	month=$(echo "$1" | tr '[:upper:]' '[:lower:]')
	case "$month" in
	january) echo "01" ;;
	february) echo "02" ;;
	march) echo "03" ;;
	april) echo "04" ;;
	may) echo "05" ;;
	june) echo "06" ;;
	july) echo "07" ;;
	august) echo "08" ;;
	september) echo "09" ;;
	october) echo "10" ;;
	november) echo "11" ;;
	december) echo "12" ;;
	*)
		echo "Error: Invalid month: $month" >&2
		exit 1
		;;
	esac
}

# Resolve month name to YYYY-MM format
# If month > current month, assumes previous year
resolve_month_year() {
	local month_name="$1"
	local month_num=$(month_to_number "$month_name")
	local current_month=$(date +%m)
	local current_year=$(date +%Y)

	# If specified month > current month, use previous year
	if [[ "$month_num" -gt "$current_month" ]]; then
		current_year=$((current_year - 1))
	fi

	echo "${current_year}-${month_num}"
}

# Get previous month in YYYY-MM format
get_previous_month() {
	local current_month=$(date +%m)
	local current_year=$(date +%Y)

	if [[ "$current_month" == "01" ]]; then
		echo "$((current_year - 1))-12"
	else
		printf "%d-%02d" "$current_year" "$((10#$current_month - 1))"
	fi
}

# Generate list of months in range (YYYY-MM format)
generate_month_range() {
	local from_month="$1"
	local to_month="$2"

	local current="$from_month"
	while [[ "$current" < "$to_month" ]] || [[ "$current" == "$to_month" ]]; do
		echo "$current"

		# Increment month (handle both GNU and BSD date)
		local year="${current%-*}"
		local month="${current#*-}"

		# Remove leading zero for arithmetic
		month=$((10#$month + 1))

		if [[ $month -gt 12 ]]; then
			year=$((year + 1))
			month=1
		fi

		current=$(printf "%d-%02d" "$year" "$month")
	done
}

# Normalize month input (name or YYYY-MM) to YYYY-MM format
normalize_month() {
	local input="$1"

	# Check if already in YYYY-MM format
	if [[ "$input" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
		echo "$input"
	else
		# Assume it's a month name
		resolve_month_year "$input"
	fi
}

# Normalize month inputs and apply defaults
if [[ -z "$MONTH" ]] && [[ -z "$FROM_MONTH" ]]; then
	# No month specified, default to previous month
	MONTH=$(get_previous_month)
	echo "No month specified, defaulting to previous month: $MONTH" >&2
fi

# Normalize month inputs (convert month names to YYYY-MM)
if [[ -n "$MONTH" ]]; then
	MONTH=$(normalize_month "$MONTH")

	# Warn if exporting current month
	current_month=$(date +%Y-%m)
	if [[ "$MONTH" == "$current_month" ]]; then
		echo "Warning: Exporting current month ($MONTH) - data may be incomplete" >&2
	fi
fi

if [[ -n "$FROM_MONTH" ]]; then
	FROM_MONTH=$(normalize_month "$FROM_MONTH")
fi

if [[ -n "$TO_MONTH" ]]; then
	TO_MONTH=$(normalize_month "$TO_MONTH")

	# Warn if range includes current month
	current_month=$(date +%Y-%m)
	if [[ "$TO_MONTH" == "$current_month" ]]; then
		echo "Warning: Range includes current month ($TO_MONTH) - data may be incomplete" >&2
	fi
fi

# Setup temp directory and cleanup trap
TEMP_DIR=$(mktemp -d)
trap cleanup EXIT INT TERM

# Create archive directory structure
ARCHIVE_NAME="synqly-billing-export-$(date +%Y-%m-%d-%H%M%S)"
ARCHIVE_DIR="${TEMP_DIR}/${ARCHIVE_NAME}"
mkdir -p "$ARCHIVE_DIR"

# Setup logging
LOG_FILE="${ARCHIVE_DIR}/export.log"

# Display processing plan
echo "Billing Export Configuration:" >&2
echo "  URL: $URL" >&2
echo "  User: $USER" >&2
echo "  Output: $OUTPUT_DIR" >&2

if [[ -n "$MONTH" ]]; then
	echo "  Month: $MONTH" >&2
else
	echo "  Month range: $FROM_MONTH to $TO_MONTH" >&2
fi
echo >&2

log "Starting billing export"
log "URL: $URL"
log "User: $USER"
log "Output directory: $OUTPUT_DIR"

# Determine list of months to export
if [[ -n "$MONTH" ]]; then
	MONTHS=("$MONTH")
	log "Exporting single month: $MONTH"
else
	MONTHS=($(generate_month_range "$FROM_MONTH" "$TO_MONTH"))
	log "Exporting month range: $FROM_MONTH to $TO_MONTH"
fi

# Fetch Synqly version
echo "Fetching Synqly version..." >&2
log "Fetching Synqly version"
SYNQLY_VERSION=$(get_synqly_version)
echo "  Synqly version: $SYNQLY_VERSION" >&2
log "Synqly version: $SYNQLY_VERSION"

# Authenticate and get access token
echo "Authenticating as $USER..." >&2
log "Authenticating as $USER"
ACCESS_TOKEN=$(authenticate)
echo "  Authentication successful" >&2
log "Authentication successful"
echo >&2

# Format month as filename (YYYY-MM -> january-2026)
format_month_name() {
	local month="$1" # YYYY-MM format
	local year="${month%-*}"
	local month_num="${month#*-}"

	# Strip leading zero
	month_num=$((10#$month_num))

	# Convert to month name
	local month_name=""
	case "$month_num" in
	1) month_name="january" ;;
	2) month_name="february" ;;
	3) month_name="march" ;;
	4) month_name="april" ;;
	5) month_name="may" ;;
	6) month_name="june" ;;
	7) month_name="july" ;;
	8) month_name="august" ;;
	9) month_name="september" ;;
	10) month_name="october" ;;
	11) month_name="november" ;;
	12) month_name="december" ;;
	esac

	echo "${year}-${month_name}"
}

# Fetch billing data for a single month with pagination
fetch_billing_data() {
	local month="$1" # Format: YYYY-MM
	local all_data="[]"
	local cursor=""

	# Extract month name from YYYY-MM format for API query
	local month_name=$(format_month_name "$month" | sed 's/^[0-9]*-//') # Get just the month name

	while true; do
		# Use correct filter syntax: month[eq]january (URL-encoded as month%5beq%5d)
		local url="${URL}/v1/billing?filter=month%5beq%5d${month_name}"
		if [[ -n "$cursor" ]]; then
			url="${url}&start_after=${cursor}"
		fi

		log "Calling billing API: $url"

		local response
		response=$(curl -s $INSECURE \
			-H "Authorization: Bearer ${ACCESS_TOKEN}" \
			"$url")

		if [[ $? -ne 0 ]]; then
			echo "Error: Failed to fetch billing data for ${month}" >&2
			exit 1
		fi

		# Check if response is valid JSON before parsing
		if ! echo "$response" | jq empty 2>/dev/null; then
			echo "Error: Invalid JSON response from billing API" >&2
			echo "URL called: $url" >&2
			echo "Response (first 500 chars): ${response:0:500}" >&2
			exit 1
		fi

		local error=$(echo "$response" | jq -r '.error // empty')
		if [[ -n "$error" ]]; then
			echo "Error fetching billing data: $error" >&2
			exit 1
		fi

		# Extract data array
		local data=$(echo "$response" | jq '.result // []')
		local count=$(echo "$data" | jq 'length')

		# Merge with existing data
		all_data=$(echo "$all_data" "$data" | jq -s 'add')

		# Check for more pages
		cursor=$(echo "$response" | jq -r '.cursor // empty')
		if [[ -z "$cursor" ]]; then
			break
		fi
	done

	echo "$all_data"
}

# Generate CSV file from billing data JSON
generate_csv() {
	local json_file="$1"
	local csv_file="$2"

	# Extract header from first record and append Deleted column
	local header
	header=$(jq -r '.[0].csv_data // ""' "$json_file" | head -n1)
	echo "${header},Deleted" >"$csv_file"

	# Process each organization's csv_data
	jq -c '.[]' "$json_file" | while IFS= read -r record; do
		local csv_data=$(echo "$record" | jq -r '.csv_data // ""')
		local deleted="false"
		local first_line=true

		while IFS= read -r line; do
			# Skip header line (first line)
			if [[ "$first_line" == true ]]; then
				first_line=false
				continue
			fi

			# If we see DELETED marker, set flag for all subsequent rows and skip the line
			if [[ "$line" == "DELETED" ]]; then
				deleted="true"
				continue
			fi

			# If we see TOTAL, stop processing (skip TOTAL and summary row after it)
			if [[ "$line" == "TOTAL" ]]; then
				break
			fi

			# Skip empty lines
			if [[ -z "$line" ]]; then
				continue
			fi

			# Output detail row with deleted column
			echo "${line},${deleted}"
		done <<<"$csv_data"
	done >>"$csv_file"
}

# Generate metadata.json file
generate_metadata() {
	local months_json="[]"
	if [[ ${#MONTHS_EXPORTED[@]} -gt 0 ]]; then
		months_json=$(printf '%s\n' "${MONTHS_EXPORTED[@]}" | jq -R . | jq -s .)
	fi
	cat >"${ARCHIVE_DIR}/metadata.json" <<EOF
{
  "export_timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "synqly_version": "${SYNQLY_VERSION}",
  "months_included": ${months_json},
  "source_url": "${URL}"
}
EOF
}

# Create tar.gz archive
create_archive() {
	# Move CSV files to archive directory
	for csv_file in "${TEMP_DIR}"/*.csv; do
		if [[ -f "$csv_file" ]]; then
			mv "$csv_file" "${ARCHIVE_DIR}/"
			log "Added $(basename "$csv_file") to archive"
		fi
	done

	# Generate metadata
	generate_metadata
	log "Generated metadata.json"

	# Create archive
	local archive_name="${ARCHIVE_NAME}.tar.gz"
	local output_file="${OUTPUT_DIR}/${archive_name}"
	tar -czf "$output_file" -C "$TEMP_DIR" "$ARCHIVE_NAME"

	if [[ $? -eq 0 ]]; then
		log "Export complete: ${output_file}"
		echo "$output_file"
	else
		log "ERROR: Failed to create archive"
		exit 1
	fi
}

# Collect billing data for all requested months
collect_billing_data() {
	local months=("$@")

	for month in "${months[@]}"; do
		local month_name=$(format_month_name "$month")
		log "Fetching billing data for ${month_name}..."

		local data=$(fetch_billing_data "$month")
		echo $data >/tmp/data.json
		local count=$(echo "$data" | jq 'length')

		if [[ "$count" == "0" ]]; then
			log "Warning: No data for ${month_name}, skipping"
			continue
		fi

		log "Retrieved ${count} organization records"

		# Store JSON data
		local json_file="${TEMP_DIR}/${month_name}.json"
		echo "$data" >"$json_file"

		# Generate CSV from billing data
		local csv_file="${TEMP_DIR}/${month_name}.csv"
		log "Generating ${month_name}.csv..."
		generate_csv "$json_file" "$csv_file"

		# Count CSV rows (excluding empty lines)
		local row_count=$(grep -c . "$csv_file" || echo "0")
		log "${row_count} CSV rows written"

		# Track exported months for metadata
		MONTHS_EXPORTED+=("$month_name")
	done
}

# Collect billing data
log "Collecting billing data for ${#MONTHS[@]} month(s)"
collect_billing_data "${MONTHS[@]}"

# Create archive
log "Creating archive"
OUTPUT_FILE=$(create_archive)

echo "$OUTPUT_FILE"

# Output sending instructions
echo >&2
echo "Send to: monthlyusagereport@synqly.com" >&2
if [[ ${#MONTHS_EXPORTED[@]} -eq 1 ]]; then
	echo "Subject: <Your Company>: ${MONTHS_EXPORTED[0]}" >&2
elif [[ ${#MONTHS_EXPORTED[@]} -gt 1 ]]; then
	last_idx=$((${#MONTHS_EXPORTED[@]} - 1))
	echo "Subject: <Your Company>: ${MONTHS_EXPORTED[0]} to ${MONTHS_EXPORTED[$last_idx]}" >&2
fi
