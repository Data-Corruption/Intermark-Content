#!/bin/bash

# This script ensures that all Markdown files in the repository have a unique ID
# in the form of an HTML comment at the beginning of the file. The script also
# maintains a JSON file to track the IDs and their corresponding relative paths.
# It updates the relative paths if they change and generates new IDs for files
# that lack one. It will fail if an ID is not found in any file or if it finds
# duplicate IDs. Serves as "delete confirmation" for files in the repository.
# To delete a file safely, remove its entry from the JSON file.

# Run from the root of the repository.

set -e
set -o pipefail

# Variables =================

id_tracker_file="./.github/ids.json"
id_length=6

declare -A tracked_id_map  # Expected ID -> rel_path mappings from JSON file
declare -A actual_id_map   # Observed ID -> rel_path mappings from scanning
pending_id_files=()        # Files needing an ID

# Functions =================

log_info() { echo -e "$1"; }
log_success() { echo -e "🟢 $1"; }
log_warning() { echo -e "🟡 $1"; }
log_error() { echo -e "🔴 $1"; exit 1; }

gen_id() {
  local max_attempts=5 attempt=0 new_id
  while (( attempt < max_attempts )); do
    new_id=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$id_length")
    if [[ -z "${tracked_id_map[$new_id]}" ]]; then
      echo "$new_id"
      return 0
    fi
    ((attempt++))
  done
  log_error "Failed to generate a unique ID after $max_attempts attempts"
}

prepend_to_file() {
  local file_path="$1" content="$2" tmp
  tmp=$(mktemp)
  {
    echo "$content"
    cat "$file_path"
  } > "$tmp"
  mv "$tmp" "$file_path"
}

# Main ======================

# Check for jq and install if missing
if ! command -v jq >/dev/null; then
  log_info "jq not found. Installing jq..."
  if command -v apt-get >/dev/null; then
    sudo apt-get update && sudo apt-get install -y jq
  elif command -v brew >/dev/null; then
    brew install jq
  elif command -v yum >/dev/null; then
    sudo yum install -y jq
  else
    log_error "No supported package manager found. Please install jq manually."
  fi
fi

# Ensure .github directory exists
mkdir -p "$(dirname "$id_tracker_file")"

# Load tracked mappings from JSON file
if [ -f "$id_tracker_file" ]; then
  while IFS=$'\t' read -r key value; do
    tracked_id_map["$key"]="$value"
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$id_tracker_file")
else
  log_warning "$id_tracker_file not found. Creating a new ID file..."
fi
log_info "Found ${#tracked_id_map[@]} IDs in $id_tracker_file"

# Get actual mappings, queue files needing an ID, err on duplicate IDs
while IFS= read -r -d '' file; do
  rel_path=$(realpath --relative-to=. "$file")
  first_line=$(head -n 1 "$file")
  if [[ "$first_line" =~ ^\<\!--\ ID:\ ([A-Za-z0-9]+)\ --\>$ ]]; then
    token="${BASH_REMATCH[1]}"
    if [[ -n "${actual_id_map[$token]}" ]]; then
      log_error "Duplicate ID $token found in $rel_path and ${actual_id_map[$token]}"
    fi
    actual_id_map["$token"]="$rel_path"
  else
    pending_id_files+=("$file")
  fi
done < <(find . -type f -name "*.md" -print0)

# Update relative paths that have changed
for token in "${!tracked_id_map[@]}"; do
  if [[ -n "${actual_id_map[$token]}" ]]; then
    if [ "${tracked_id_map[$token]}" != "${actual_id_map[$token]}" ]; then
      log_info "Updating relative path for ID $token from ${tracked_id_map[$token]} to ${actual_id_map[$token]}"
      tracked_id_map["$token"]="${actual_id_map[$token]}"
    fi
  else
    log_error "ID $token not found in any files"
  fi
done

# Add untracked IDs to the tracker
for token in "${!actual_id_map[@]}"; do
  if [[ -z "${tracked_id_map[$token]}" ]]; then
    log_warning "Adding untracked ID $token from ${actual_id_map[$token]}"
    tracked_id_map["$token"]="${actual_id_map[$token]}"
  fi
done

# Generate new IDs for files that need one, prepend to file, add to tracker
for file in "${pending_id_files[@]}"; do
  file_id=$(gen_id)
  rel_path=$(realpath --relative-to=. "$file")
  log_info "Adding new ID $file_id to $rel_path"
  prepend_to_file "$file" "<!-- ID: $file_id -->"
  tracked_id_map["$file_id"]="$rel_path"
done

# Write updated mappings to JSON file
json_str="{"
for key in "${!tracked_id_map[@]}"; do
  value="${tracked_id_map[$key]//\"/\\\"}"  # simple escape (assuming no complex cases)
  json_str+="\"$key\": \"$value\","
done
json_str="${json_str%,}"
json_str="${json_str}}"
echo "$json_str" | jq . > "$id_tracker_file"

log_success "Successfully validated/updated all IDs"
