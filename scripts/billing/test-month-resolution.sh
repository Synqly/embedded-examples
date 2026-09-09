#!/bin/bash
# Test month resolution functions
set -euo pipefail

# Source functions inline for testing
month_to_number() {
    local month
    month=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$month" in
        january)   echo "01";;
        february)  echo "02";;
        march)     echo "03";;
        april)     echo "04";;
        may)       echo "05";;
        june)      echo "06";;
        july)      echo "07";;
        august)    echo "08";;
        september) echo "09";;
        october)   echo "10";;
        november)  echo "11";;
        december)  echo "12";;
        *) echo "Error: Invalid month: $month" >&2; exit 1;;
    esac
}

resolve_month_year() {
    local month_name="$1"
    local month_num=$(month_to_number "$month_name")
    local current_month=$(date +%m)
    local current_year=$(date +%Y)

    if [[ $((10#$month_num)) -gt $((10#$current_month)) ]]; then
        current_year=$((current_year - 1))
    fi

    echo "${current_year}-${month_num}"
}

get_previous_month() {
    local current_month=$(date +%m)
    local current_year=$(date +%Y)

    if [[ "$current_month" == "01" ]]; then
        echo "$((current_year - 1))-12"
    else
        printf "%d-%02d" "$current_year" "$((10#$current_month - 1))"
    fi
}

generate_month_range() {
    local from_month="$1"
    local to_month="$2"

    local current="$from_month"
    while [[ "$current" < "$to_month" ]] || [[ "$current" == "$to_month" ]]; do
        echo "$current"

        local year="${current%-*}"
        local month="${current#*-}"

        month=$((10#$month + 1))

        if [[ $month -gt 12 ]]; then
            year=$((year + 1))
            month=1
        fi

        current=$(printf "%d-%02d" "$year" "$month")
    done
}

normalize_month() {
    local input="$1"

    if [[ "$input" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        echo "$input"
    else
        resolve_month_year "$input"
    fi
}

echo "Testing month resolution functions..."
echo

# Test 1: Month name to number
echo "Test 1: month_to_number"
test_month_to_num() {
    local result=$(month_to_number "$1")
    if [[ "$result" == "$2" ]]; then
        echo "  ✓ $1 -> $result"
    else
        echo "  ✗ $1 -> Expected $2, got $result"
        exit 1
    fi
}

test_month_to_num "january" "01"
test_month_to_num "february" "02"
test_month_to_num "march" "03"
test_month_to_num "december" "12"
test_month_to_num "JANUARY" "01"  # Case insensitive
echo

# Test 2: Previous month calculation
echo "Test 2: get_previous_month"
prev=$(get_previous_month)
echo "  Previous month: $prev"
if [[ "$prev" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
    echo "  ✓ Format is valid (YYYY-MM)"
else
    echo "  ✗ Invalid format: $prev"
    exit 1
fi
echo

# Test 3: Month range generation
echo "Test 3: generate_month_range"
echo "  Range 2025-11 to 2026-01:"
generate_month_range "2025-11" "2026-01" | while read -r month; do
    echo "    - $month"
done
echo

# Test 4: Month normalization
echo "Test 4: normalize_month"
test_normalize() {
    local result=$(normalize_month "$1")
    echo "  $1 -> $result"
}

test_normalize "2026-01"
test_normalize "january"
test_normalize "march"
echo

# Test 5: Year resolution (simulate different months)
echo "Test 5: Year resolution logic"
echo "  Current month: $(date +%Y-%m)"
echo "  Testing resolve_month_year with 'march':"
result=$(resolve_month_year "march")
echo "    march -> $result"
echo

echo "All tests passed!"
