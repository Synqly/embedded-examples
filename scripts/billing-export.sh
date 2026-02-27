#!/bin/bash
set -euo pipefail

# ─── Functions ───────────────────────────────────────────

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
		if ! command -v "$cmd" >/dev/null 2>&1; then
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

	# 4. stdin pipe or interactive prompt
	if [[ -t 0 ]]; then
		read -rsp "Password: " PASSWORD
		echo >&2
	else
		read -r PASSWORD
	fi
}

# Month utilities

MONTH_NAMES=(january february march april may june july august september october november december)

# Convert month name to number (01-12)
month_to_number() {
	local month
	month=$(echo "$1" | tr '[:upper:]' '[:lower:]')
	for i in "${!MONTH_NAMES[@]}"; do
		if [[ "${MONTH_NAMES[$i]}" == "$month" ]]; then
			printf "%02d" "$((i + 1))"
			return
		fi
	done
	echo "Error: Invalid month: $month" >&2
	exit 1
}

# Convert month number (1-12) to name
number_to_month_name() {
	local month_num="$1"
	if [[ $month_num -lt 1 || $month_num -gt 12 ]]; then
		echo "Error: Invalid month number: $month_num" >&2
		exit 1
	fi
	echo "${MONTH_NAMES[$((month_num - 1))]}"
}

# Resolve month name to YYYY-MM format
# If month > current month, assumes previous year
resolve_month_year() {
	local month_name="$1"
	local month_num
	month_num=$(month_to_number "$month_name")
	local current_month
	current_month=$(date +%m)
	local current_year
	current_year=$(date +%Y)

	# If specified month > current month, use previous year
	if [[ "$month_num" -gt "$current_month" ]]; then
		current_year=$((current_year - 1))
	fi

	echo "${current_year}-${month_num}"
}

# Get previous month in YYYY-MM format
get_previous_month() {
	local current_month
	current_month=$(date +%m)
	local current_year
	current_year=$(date +%Y)

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
		return
	fi

	# Assume it's a month name
	resolve_month_year "$input"
}

# Format month as filename (YYYY-MM -> 2026-january)
format_month_name() {
	local month="$1" # YYYY-MM format
	local year="${month%-*}"
	local month_num="${month#*-}"

	# Strip leading zero
	month_num=$((10#$month_num))

	local month_name
	month_name=$(number_to_month_name "$month_num")

	echo "${year}-${month_name}"
}

# Get Synqly version (unauthenticated)
get_synqly_version() {
	local response
	local curl_rc=0
	response=$(curl "${CURL_OPTS[@]}" "${URL}/v1/version") || curl_rc=$?
	if [[ $curl_rc -ne 0 ]]; then
		echo "Error: Failed to connect to ${URL}" >&2
		exit 1
	fi
	echo "$response" | jq -r '.version // "unknown"'
}

# Authenticate and get access token
authenticate() {
	local body
	body=$(jq -n --arg name "$SYNQLY_USER" --arg secret "$PASSWORD" '{name: $name, secret: $secret}')

	local response
	local curl_rc=0
	response=$(curl "${CURL_OPTS[@]}" -X POST \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer ${TOKEN}" \
		-d "$body" \
		"${URL}/v1/auth/logon/synqly-backoffice") || curl_rc=$?

	if [[ $curl_rc -ne 0 ]]; then
		echo "Error: Network error during authentication" >&2
		exit 1
	fi

	# Check for API-level errors (4xx/5xx responses with .message)
	local api_error
	api_error=$(echo "$response" | jq -r '.message // empty')
	if [[ -n "$api_error" ]]; then
		echo "Authentication failed: $api_error" >&2
		exit 1
	fi

	# Check auth_code for authentication result
	local auth_code
	auth_code=$(echo "$response" | jq -r '.result.auth_code // empty')
	if [[ "$auth_code" != "success" ]]; then
		local auth_msg
		auth_msg=$(echo "$response" | jq -r '.result.auth_msg // "authentication failed"')
		echo "Authentication failed: $auth_msg (code: $auth_code)" >&2
		exit 1
	fi

	local token
	token=$(echo "$response" | jq -r '.result.token.access.secret // empty')
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
	local timestamp
	timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	echo "${timestamp} $1" | tee -a "$LOG_FILE" >&2
}

# Argument validation helper: require_arg <flag_name> <caller_argc>
require_arg() {
	if [[ $2 -lt 2 ]]; then
		echo "Error: $1 requires a value" >&2
		exit 1
	fi
}

# Fetch billing data for a single month with pagination
fetch_billing_data() {
	local month="$1" # Format: YYYY-MM
	local all_data="[]"
	local cursor=""

	# Extract month name from YYYY-MM format for API query
	local month_num="${month#*-}"
	month_num=$((10#$month_num))
	local month_name
	month_name=$(number_to_month_name "$month_num")

	while true; do
		# Use correct filter syntax: month[eq]january (URL-encoded as month%5beq%5d)
		local url="${URL}/v1/billing?filter=month%5beq%5d${month_name}"
		if [[ -n "$cursor" ]]; then
			url="${url}&start_after=${cursor}"
		fi

		log "Calling billing API: $url"

		local response
		local curl_rc=0
		response=$(curl "${CURL_OPTS[@]}" \
			-H "Authorization: Bearer ${ACCESS_TOKEN}" \
			"$url") || curl_rc=$?

		if [[ $curl_rc -ne 0 ]]; then
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

		local error
		error=$(echo "$response" | jq -r '.error // empty')
		if [[ -n "$error" ]]; then
			echo "Error fetching billing data: $error" >&2
			exit 1
		fi

		# Extract data array
		local data
		data=$(echo "$response" | jq '.result // []')
		local count
		count=$(echo "$data" | jq 'length')

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
#
# Expected csv_data format per record:
#   - Header row (column names)
#   - Detail rows (one per line item)
#   - "DELETED" sentinel (marks subsequent rows as deleted orgs)
#   - "TOTAL" sentinel (followed by a summary row; both are skipped)
generate_csv() {
	local json_file="$1"
	local csv_file="$2"

	if ! jq empty "$json_file" 2>/dev/null; then
		echo "Error: Invalid JSON in $json_file" >&2
		exit 1
	fi

	# Extract header from first record and append Deleted column
	local header
	header=$(jq -r '.[0].csv_data // ""' "$json_file" | head -n1)
	echo "${header},Deleted" >"$csv_file"

	# Process each organization's csv_data
	jq -c '.[]' "$json_file" | while IFS= read -r record; do
		local csv_data
		csv_data=$(echo "$record" | jq -r '.csv_data // ""')
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
	local tar_rc=0
	tar -czf "$output_file" -C "$TEMP_DIR" "$ARCHIVE_NAME" || tar_rc=$?

	if [[ $tar_rc -ne 0 ]]; then
		log "ERROR: Failed to create archive"
		exit 1
	fi

	log "Export complete: ${output_file}"
	echo "$output_file"
}

# Collect billing data for all requested months
collect_billing_data() {
	local months=("$@")

	for month in "${months[@]}"; do
		local month_name
		month_name=$(format_month_name "$month")
		log "Fetching billing data for ${month_name}..."

		local data
		data=$(fetch_billing_data "$month")
		local count
		count=$(echo "$data" | jq 'length')

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
		local row_count
		row_count=$(grep -c . "$csv_file" || echo "0")
		log "${row_count} CSV rows written"

		# Track exported months for metadata
		MONTHS_EXPORTED+=("$month_name")
	done
}

# ─── Main ────────────────────────────────────────────────

# Defaults
OUTPUT_DIR="."
CURL_OPTS=(-sS)
INSECURE=false
MONTH=""
FROM_MONTH=""
TO_MONTH=""
PASSWORD=""
PASSWORD_FILE=""
TOKEN=""
TOKEN_FILE=""
URL=""
SYNQLY_USER=""
TEMP_DIR=""
MONTHS_EXPORTED=()

# Show usage if no arguments provided
if [[ $# -eq 0 ]]; then
	show_usage
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
	case $1 in
	--help | -h)
		show_usage
		;;
	--url)
		require_arg "$1" $#
		URL="$2"
		shift 2
		;;
	--token)
		require_arg "$1" $#
		TOKEN="$2"
		shift 2
		;;
	--token-file)
		require_arg "$1" $#
		TOKEN_FILE="$2"
		shift 2
		;;
	--user)
		require_arg "$1" $#
		SYNQLY_USER="$2"
		shift 2
		;;
	--password)
		require_arg "$1" $#
		PASSWORD="$2"
		shift 2
		;;
	--password-file)
		require_arg "$1" $#
		PASSWORD_FILE="$2"
		shift 2
		;;
	--month)
		require_arg "$1" $#
		MONTH="$2"
		shift 2
		;;
	--from)
		require_arg "$1" $#
		FROM_MONTH="$2"
		shift 2
		;;
	--to)
		require_arg "$1" $#
		TO_MONTH="$2"
		shift 2
		;;
	--output)
		require_arg "$1" $#
		OUTPUT_DIR="$2"
		shift 2
		;;
	--insecure)
		CURL_OPTS+=(-k)
		INSECURE=true
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

# Validate required arguments
if [[ -z "$URL" ]]; then
	echo "Error: --url is required" >&2
	exit 1
fi

if [[ -z "$SYNQLY_USER" ]]; then
	echo "Error: --user is required" >&2
	exit 1
fi

# Warn if insecure mode is enabled
if [[ "$INSECURE" == true ]]; then
	echo "WARNING: SSL certificate verification is disabled" >&2
fi

# Resolve token from multiple sources
resolve_token

# Resolve password from multiple sources
resolve_password

# Validate time period arguments
if [[ -n "$MONTH" ]] && { [[ -n "$FROM_MONTH" ]] || [[ -n "$TO_MONTH" ]]; }; then
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

# Normalize month inputs and apply defaults
if [[ -z "$MONTH" ]] && [[ -z "$FROM_MONTH" ]]; then
	# No month specified, default to previous month
	MONTH=$(get_previous_month)
	echo "No month specified, defaulting to previous month: $MONTH" >&2
fi

# Normalize month inputs (convert month names to YYYY-MM)
current_month=$(date +%Y-%m)

if [[ -n "$MONTH" ]]; then
	MONTH=$(normalize_month "$MONTH")

	# Warn if exporting current month
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
	if [[ "$TO_MONTH" == "$current_month" ]]; then
		echo "Warning: Range includes current month ($TO_MONTH) - data may be incomplete" >&2
	fi
fi

# Validate from/to ordering (after normalization to YYYY-MM)
if [[ -n "$FROM_MONTH" ]] && [[ -n "$TO_MONTH" ]] && [[ "$FROM_MONTH" > "$TO_MONTH" ]]; then
	echo "Error: --from ($FROM_MONTH) must not be after --to ($TO_MONTH)" >&2
	exit 1
fi

# Validate output directory exists
if [[ ! -d "$OUTPUT_DIR" ]]; then
	echo "Error: Output directory does not exist: $OUTPUT_DIR" >&2
	exit 1
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
log "Starting billing export"
log "URL: $URL"
log "User: $SYNQLY_USER"
log "Output directory: $OUTPUT_DIR"

if [[ -n "$MONTH" ]]; then
	log "Month: $MONTH"
else
	log "Month range: $FROM_MONTH to $TO_MONTH"
fi

# Determine list of months to export
if [[ -n "$MONTH" ]]; then
	MONTHS=("$MONTH")
	log "Exporting single month: $MONTH"
else
	MONTHS=()
	while IFS= read -r line; do
		MONTHS+=("$line")
	done < <(generate_month_range "$FROM_MONTH" "$TO_MONTH")
	log "Exporting month range: $FROM_MONTH to $TO_MONTH"
fi

# Fetch Synqly version
log "Fetching Synqly version"
SYNQLY_VERSION=$(get_synqly_version)
log "Synqly version: $SYNQLY_VERSION"

# Authenticate and get access token
log "Authenticating as $SYNQLY_USER"
ACCESS_TOKEN=$(authenticate)
log "Authentication successful"

# Collect billing data
log "Collecting billing data for ${#MONTHS[@]} month(s)"
collect_billing_data "${MONTHS[@]}"

# Guard against empty export
if [[ ${#MONTHS_EXPORTED[@]} -eq 0 ]]; then
	echo "No billing data was exported." >&2
	exit 0
fi

# Create archive
log "Creating archive"
OUTPUT_FILE=$(create_archive)

# Archive path goes to stdout (for piping); instructions go to stderr
echo "$OUTPUT_FILE"

echo >&2
echo "Send to: monthlyusagereport@synqly.com" >&2
if [[ ${#MONTHS_EXPORTED[@]} -eq 1 ]]; then
	echo "Subject: <Your Company>: ${MONTHS_EXPORTED[0]}" >&2
elif [[ ${#MONTHS_EXPORTED[@]} -gt 1 ]]; then
	last_idx=$((${#MONTHS_EXPORTED[@]} - 1))
	echo "Subject: <Your Company>: ${MONTHS_EXPORTED[0]} to ${MONTHS_EXPORTED[$last_idx]}" >&2
fi
